require 'openai'
require 'rest-client'
require_relative 'openai'

module LLM
  # OpenWebUI backend.
  #
  # OpenWebUI exposes an OpenAI-compatible Chat Completions API, but it is not
  # accessed through the OpenAI ruby client.
  #
  # Historically we copied singleton methods from `LLM::OpenAI` via hooks.
  # That binds `self` to the original module and breaks internal dispatch.
  #
  # Instead, we reuse behaviour by including `OpenAIMethods` in our own methods
  # module, and compose via `prepend`.
  module OpenWebUIMethods
    include OpenAIMethods

    def client(options, messages = nil)
      url, key, model = IndiferentHash.process_options options,
        :url, :key, :model

      {
        base_url: url,
        key: key,
        model: model,
        method: :post,
        action: 'chat/completions'
      }
    end

    def query(client, messages, tools = [], parameters = {})
      base_url, key, model, method, action = IndiferentHash.process_options client.dup, :base_url, :key, :model, :method, :action
      url = File.join(base_url, action.to_s)

      parameters = parameters.dup
      parameters[:model] ||= model
      parameters[:tools] = format_tool_definitions(tools) if tools && tools.any?
      parameters[:messages] = messages
      parameters[:verify_ssl] = false

      headers = IndiferentHash.setup({ 'Authorization' => "Bearer #{key}", 'Content-Type' => 'application/json' })
      response = case method.to_sym
                 when :post
                   RestClient.post(url, parameters.to_json, headers)
                 else
                   raise 'Get not supported'
                 end

      JSON.parse(response.body)
    end

    def parse_tool_call(info)
      IndiferentHash.setup info
      arguments, name = IndiferentHash.process_options info['function'], :arguments, :name
      arguments = JSON.parse arguments
      id = info[:id] || name + '_' + Misc.digest(arguments)
      { arguments: arguments, id: id, name: name }
    end
  end

  module OpenWebUI
    TAG = 'openwebui'
    DEFAULT_MODEL = 'llama3.1'

    class << self
      prepend OpenWebUIMethods
      include Backend::ClassMethods
    end
  end
end
