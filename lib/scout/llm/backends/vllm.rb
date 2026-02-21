require_relative 'responses'

module LLM
  # vLLM exposes an OpenAI-compatible Responses API.
  #
  # We reuse the Responses backend behaviour and only tweak tool-call parsing.
  module VLLMMethods
    include ResponsesMethods

    def parse_tool_call(info)
      tool_call = super
      name = tool_call[:name].to_s
      name.sub!(/[^a-zA-Z_]+channel[^a-zA-Z_]+[a-zA-Z_]+/, '')
      tool_call.merge(name: name)
    end
  end

  module VLLM
    TAG = 'vllm'
    DEFAULT_MODEL = 'vllm'

    class << self
      prepend VLLMMethods
      include Backend::ClassMethods
    end
  end
end
