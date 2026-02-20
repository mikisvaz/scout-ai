require 'scout'
require 'anthropic'
require_relative 'default'

module LLM
  module AnthropicMethods
    def extra_options(options, messages = nil)
      format, max_tokens = IndiferentHash.process_options options, :format, :max_tokens, max_tokens: 1000

      options[:max_tokens] = max_tokens

      case format.to_sym
      when :json, :json_object
        options[:response_format] = { type: 'json_object' }
      else
        options[:response_format] = { type: format }
      end if format
    end

    def client(options, messages = nil)
      url, key = IndiferentHash.process_options options,
        :url, :key

      Object::Anthropic::Client.new(access_token: key)
    end

    def query(client, messages, tools = [], parameters = {})
      parameters[:messages] = messages
      parameters[:tools] = format_tool_definitions(tools) if tools && tools.any?
      client.messages(parameters: parameters)
    end

    def format_tool_definitions(tools)
      tools.values.collect do |obj, info|
        info = obj if Hash === obj
        IndiferentHash.setup(info)
        info[:type] = 'custom' if info[:type] == 'function'
        info[:input_schema] = info.delete('parameters') if info['parameters']
        info[:description] ||= ''
        info
      end
    end

    def format_tool_call(message)
      tool_call = IndiferentHash.setup(JSON.parse(message[:content]))
      arguments = tool_call.delete('arguments') || tool_call[:function].delete('arguments') || '{}'
      arguments = JSON.parse arguments if String === arguments
      name = tool_call[:name]
      id = tool_call.delete('call_id') || tool_call.delete('id') || tool_call.delete('tool_use_id')
      tool_call['id'] = id
      tool_call['type'] = 'tool_use'
      tool_call['name'] ||= name
      tool_call['input'] = arguments
      tool_call.delete :function
      { role: 'assistant', content: [tool_call] }
    end

    def format_tool_output(message, last_id = nil)
      info = JSON.parse(message[:content])
      id = info.delete('call_id') || info.delete('id') || info.delete('tool_use_id') || info[:function].delete('id')
      tool_output = { type: 'tool_result', tool_use_id: id, content: info[:content] }
      { role: 'user', content: [tool_output] }
    end

    def parse_tool_call(info)
      arguments, id, name = IndiferentHash.process_options info, :input, :id, :name
      { arguments: arguments, id: id, name: name }
    end

    def process_response(messages, response, tools, options, &block)
      Log.debug "Respose: #{Log.fingerprint response}"
      IndiferentHash.setup response

      response[:content].collect do |output|
        IndiferentHash.setup output
        case output[:type].to_s
        when 'text'
          IndiferentHash.setup({ role: :assistant, content: output[:text] })
        when 'reasoning'
          next
        when 'tool_use'
          tool_call = parse_tool_call(output)
          LLM.process_calls(tools, [tool_call], &block)
        when 'web_search_call'
          next
        else
          eee response
          eee output
          raise
        end
      end.compact.flatten
    end

    def embed_query(client, text, options = {})
      raise 'Anthropic does not offer embeddings'
    end
  end

  module Anthropic
    TAG = 'anthropic'
    DEFAULT_MODEL = 'claude-sonnet-4-5'

    class << self
      prepend AnthropicMethods
      include Backend::ClassMethods
    end
  end
end
