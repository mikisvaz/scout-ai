# Test support: LLM::Mock, an offline scripted backend.
#
# Not named test_*.rb on purpose: the Rakefile test pattern
# ('test/**/test_*.rb') must not collect this file.
#
# Registered into LLM::BACKENDS so it is reachable from LLM.ask / LLM.embed
# once the endpoint yaml selects `backend: mock`.
#
# Scripting model
# ---------------
#   LLM::Mock.responses = ['an answer']
#   LLM::Mock.responses = [{role: 'assistant', content: 'an answer'}]
#   LLM::Mock.responses = ['first', {tool_calls: [{name: 'f', arguments: {}}]}, 'final']
#   LLM::Mock.script('a') { ... }  # same, resetting first
#
# Each response entry may be:
#   * a String                          -> plain answer
#   * a Hash message (role/content)     -> one message
#   * an Array of Hash messages         -> several messages at once
#   * a Hash with :tool_calls           -> tool call round: the calls are
#     delegated to LLM.process_calls (using options[:tools]) so the
#     function_call / function_call_output messages match the real backends
#   * a Proc called with (messages, options) returning any of the above
#   * an Exception instance             -> raised
#
# Entries replay in order; when exhausted the last entry repeats.
#
# Tool loops: the real backends return output ending in a
# function_call_output message and then re-enter `ask` with
# messages + output (Backend#chain_tools). LLM.ask dispatches to the backend
# only once, so the mock drives the same rounds internally; to keep tests
# able to assert on what the model would see next, every round is recorded
# in `.calls` with the messages accumulated so far (round 1 = the original
# messages, round 2 = messages + marriages output, ...), matching the shape
# of the repeated asks of the real backends.
#
# ScoutCoder: IndiferentHash#pretty_print takes 0 args while Ruby's PP passes
# 1, so pp-ing one of these hashes inside a test failure (assertion diffs call
# PP) raises ArgumentError and hides the real failure. Use Log.fingerprint or
# .inspect when debugging IndiferentHash values in tests instead of pp.
module LLM
  module Mock
    DIMENSIONS = 64

    class << self
      attr_accessor :responses

      def script(*responses, &block)
        self.reset!
        @responses = responses.flatten
        @setup = block if block_given?
        self
      end

      def reset!
        @responses = []
        @index = 0
        @calls = []
        @setup = nil
        @tool_definitions = {}
        self
      end

      def calls
        @calls ||= []
      end

      def next_response(messages = nil, options = {})
        @index ||= 0
        @responses = [@responses].flatten.compact
        entry = @responses[@index] || @responses.last
        @index += 1

        if Proc === entry
          entry = entry.call(messages, options)
        end
        entry
      end

      def index
        @index ||= 0
      end

      #{{{ ask

      # Tool definitions resolved for the last ask (same {name => [obj, def]}
      # shape the real backends build), for assertions.
      def tool_definitions
        @tool_definitions ||= {}
      end

      def ask(messages, options = {}, &block)
        messages = Chat.setup(Chat.prepare_prompt(messages)) unless Array === messages
        options = IndiferentHash.setup(options.dup)

        # Mirror Backend::ClassMethods: resolve tool:/kb:/association:
        # directives (and explicit options[:tools]) once per ask. LLM.tools
        # consumes the directive messages, so resolve before recording.
        @tool_definitions = LLM::Mock.tools(messages, options)

        tool_calls, response = [], []
        round_messages = messages

        loop do
          calls << [round_messages, options]

          entry = next_response(round_messages, options)

          case entry
          when Hash
            if entry[:tool_calls]
              script_calls = entry[:tool_calls].collect do |info|
                info = IndiferentHash.setup(info.dup)
                { name: info[:name] || info.dig(:function, :name),
                  arguments: info[:arguments] || info.dig(:function, :arguments) || {},
                  id: info[:id] || info[:call_id] || "call_#{@index}" }
              end

              new_calls = LLM.process_calls(tool_definitions, script_calls, &block).flatten
              tool_calls.concat new_calls
              # next round sees the original messages plus the tool call
              # round, exactly like Backend#chain_tools does
              round_messages = Chat.setup(messages + tool_calls)
              next
            else
              response << IndiferentHash.setup(entry.dup)
            end
          when Array
            entry.each { |m| response << IndiferentHash.setup(m.dup) }
          when String
            response << IndiferentHash.setup(role: :assistant, content: entry)
          when nil
            response << IndiferentHash.setup(role: :assistant, content: '')
          else
            raise Exception, entry if Exception === entry
            response << IndiferentHash.setup(role: :assistant, content: entry.to_s)
          end

          break
        end

        output = (tool_calls + response).flatten

        if options[:return_messages]
          Chat.setup output
        else
          Chat.setup(output)
          cleaned = Chat.clean(output)
          return '' if cleaned.nil? || cleaned.empty?
          cleaned.last[:content]
        end
      end

      # Mirrors Backend::ClassMethods#tools: explicit options[:tools] plus the
      # tool:/kb:/association: directives resolved from the messages
      # (LLM.tools / LLM.associations -> Chat.tools / Chat.associations), so a
      # scripted tool-call round exercises the same object/definition pairing
      # the real backends use ({name => [obj, definition]}).
      #
      # ScoutCoder: 'tool:'/'association:'/'kb:' chat directives are NOT
      # resolved by LLM.ask itself; each backend's #tools(messages, options)
      # does it, and it *deletes* options[:tools] while at it. A custom backend
      # registered in LLM::BACKENDS therefore has to call LLM.tools /
      # LLM.associations itself or the directives are silently dropped.
      def tools(messages, options)
        tools = options[:tools]

        case tools
        when Array
          tools = tools.inject({}) do |acc, definition|
            definition = definition[:function] if Hash === definition && definition[:function] && definition[:name].nil?
            acc.merge(definition[:name] => [nil, definition])
          end
        when nil
          tools = {}
        end

        tools.merge!(LLM.tools(messages))
        tools.merge!(LLM.associations(messages))
        tools
      end

      #{{{ embed

      # Deterministic bag-of-words embedding: each downcased word is hashed to
      # a dimension and counted, then L2-normalized, so identical texts yield
      # identical vectors and texts sharing words land near each other
      # (cosine) for RAG nearest-neighbour assertions.
      def embed(text, _options = {})
        case text
        when Array
          text.collect { |t| embed_one(t) }
        else
          embed_one(text)
        end
      end

      def embed_one(text)
        vector = Array.new(DIMENSIONS, 0.0)

        text.to_s.downcase.split(/\W+/).each do |word|
          next if word.empty?
          position = word.sum % DIMENSIONS
          vector[position] += 1.0
        end

        norm = Math.sqrt(vector.inject(0.0) { |acc, v| v * v })
        return vector if norm.zero?
        vector.collect { |v| v / norm }
      end
    end
  end
end

LLM::BACKENDS[:mock] = LLM::Mock
