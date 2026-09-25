module LLM
  # A call-local, serializable description of the request which caused a tool
  # call. This is deliberately not a Workflow input: putting it in the input
  # hash would change Step identity and would expose private metadata to task
  # schemas.
  module RequestContext
    CONTEXT_VERSION = 1

    UNSAFE_KEYS = %w[
      agent agents client clients tools tool messages chat conversation
      previous_response_id previous_response state mutable_state proc
      credentials credential password secret api_key access_token auth_token
      authorization private_key key
    ].freeze

    module_function

    def unsafe_key?(key)
      # Hash keys can arrive from external payloads with malformed encodings;
      # normalize before any case conversion so projection cannot raise.
      key = safe_string(key.to_s).downcase
      normalized = key.gsub(/[^a-z0-9]/, '')
      UNSAFE_KEYS.include?(key) ||
        normalized.include?('credential') || normalized.include?('password') ||
        normalized.include?('secret') || normalized.include?('apikey') ||
        normalized.include?('accesstoken') || normalized.include?('authtoken') ||
        normalized.include?('authorization') || normalized.include?('privatekey') ||
        normalized.end_with?('token')
    end

    def safe_string(value)
      value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
    rescue EncodingError
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
    end
    private_class_method :safe_string

    # Return only values which can safely be serialized as JSON. This method
    # never mutates the caller's hash and omits unsafe/non-data values. JSON
    # has no representation for NaN or Infinity, so non-finite floats are
    # omitted rather than allowed to reach JSON.generate.
    def project(value)
      case value
      when NilClass, TrueClass, FalseClass
        value
      when String
        safe_string(value)
      when Integer
        value
      when Float
        value.finite? ? value : nil
      when Symbol
        safe_string(value.to_s)
      when Array
        value.collect { |item| project(item) }.compact
      when Hash
        value.each_with_object({}) do |(key, item), projected|
          next unless key.is_a?(String) || key.is_a?(Symbol)
          next if unsafe_key?(key)

          projected_key = safe_string(key.to_s).to_sym
          projected_value = project(item)
          projected[projected_key] = projected_value unless projected_value.nil?
        end
      else
        nil
      end
    end

    # Capture the caller supplied context and reliably known request
    # attributes. Existing context fields win so recursive tool rounds keep
    # the originating request description.
    def capture(seed = nil, endpoint: nil, backend: nil, model: nil)
      context = project(seed || {})
      context = {} unless Hash === context
      context[:endpoint] = endpoint.to_s unless endpoint.nil? || context.key?(:endpoint)
      context[:backend] = backend.to_s unless backend.nil? || context.key?(:backend)
      context[:model] = project(model) unless model.nil? || context.key?(:model)
      context.delete_if { |_key, value| value.nil? }
      context
    end

    # Extension point for backend-specific effective resolution. Backends may
    # call this with a model discovered while preparing their client; no
    # provider object or credential is ever placed in the projection.
    def augment(context, backend: nil, model: nil)
      capture(context, backend: backend, model: model)
    end

    # Versioned metadata envelope kept in Step info, never task inputs.
    def envelope(context)
      fields = project(context || {})
      fields = {} unless Hash === fields
      {version: CONTEXT_VERSION, fields: fields}
    end

    # Read current envelopes and legacy unversioned metadata. Unknown future
    # envelope versions are intentionally not interpreted.
    def fields_from(envelope)
      return nil unless Hash === envelope

      version = envelope[:version] || envelope['version']
      if version
        return nil unless version.to_i == CONTEXT_VERSION
        fields = project(envelope[:fields] || envelope['fields'])
        Hash === fields ? fields : {}
      else
        fields = project(envelope)
        Hash === fields ? fields : {}
      end
    end

    # Per-job extension installed only on Steps dispatched with context.
    # ScoutCoder: Step#run resets info before task execution, so context must
    # be reattached through this instance-level reset_info hook, not only set
    # on the Step before run starts.
    # Scout Gear resets .info at the start of Step#run; overriding that
    # instance's reset_info reattaches the envelope to each reset, before the
    # task block executes. No upstream class is modified globally.
    module StepExtension
      def register_request_context(context)
        projected = RequestContext.envelope(context)
        request_context_mutex.synchronize do
          existing = info.find { |key, _value| key.to_s == 'request_context' }&.last
          @llm_request_context_envelope ||= existing || projected
        end
        self
      end

      # This helper can be called without qualification inside a workflow task
      # body, which Scout executes with the Step as its receiver.
      def request_context
        RequestContext.fields_from(info[:request_context])
      end

      def reset_info(new_info = {})
        envelope = @llm_request_context_envelope
        return super(new_info) unless envelope

        FileUtils.mkdir_p(File.dirname(info_file))
        lock_path = "#{info_file}.request_context.lock"
        File.open(lock_path, 'a') do |lock|
          lock.flock(File::LOCK_EX)
          load_info
          existing = info.find { |key, _value| key.to_s == 'request_context' }&.last
          envelope = @llm_request_context_envelope = existing if existing
          new_info = new_info.dup
          new_info.delete_if { |key, _value| key.to_s == 'request_context' }
          new_info[:request_context] = envelope
          super(new_info)
        ensure
          lock.flock(File::LOCK_UN) rescue nil
        end
      end

      # A workflow task's dependencies are separate Steps with separate info
      # files. Pass context only to actual dependencies immediately before
      # Scout executes them; their own reset_info persists it before the body.
      def run_dependencies
        context = request_context
        if context
          all_dependencies.each do |dependency|
            dependency.extend(RequestContext::StepExtension)
            dependency.register_request_context(context)
          end
        end
        super
      end

      # Exported / explicit exec dispatches call Step#exec directly and do not
      # pass through Step#run's reset_info. Persist before entering that task.
      def exec
        persist_request_context!
        super
      end

      private

      def request_context_mutex
        @llm_request_context_mutex ||= Mutex.new
      end

      def persist_request_context!
        envelope = @llm_request_context_envelope
        return unless envelope

        FileUtils.mkdir_p(File.dirname(info_file))
        lock_path = "#{info_file}.request_context.lock"
        File.open(lock_path, 'a') do |lock|
          lock.flock(File::LOCK_EX)
          current = info
          unless current.keys.any? { |key| key.to_s == 'request_context' }
            merge_info(request_context: envelope)
            save_info
          end
        ensure
          lock.flock(File::LOCK_UN) rescue nil
        end
      end
    end

    # Scout Gear has no producer-completion callback. Callers therefore invoke
    # this only after a real producer run and pass produced: true. The lock and
    # second sidecar read make the fallback first-writer-wins when two cold
    # producers race; a replay never overwrites the original context.
    def write_producer_context(step, context, produced:)
      return unless produced && step.done?

      lock_path = "#{step.info_file}.request_context.lock"
      File.open(lock_path, 'a') do |lock|
        lock.flock(File::LOCK_EX)
        info = step.info
        return if info.keys.any? { |key| key.to_s == 'request_context' }

        step.merge_info(request_context: envelope(context))
        step.save_info
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end
  end
end
