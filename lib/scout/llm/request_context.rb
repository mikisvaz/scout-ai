module LLM
  # A call-local, serializable description of the request which caused a tool
  # call. This is deliberately not a Workflow input: putting it in the input
  # hash would change Step identity and would expose private metadata to task
  # schemas.
  module RequestContext
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

        step.merge_info(request_context: project(context))
        step.save_info
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end
  end
end
