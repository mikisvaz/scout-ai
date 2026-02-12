require 'openai'
require 'rest-client'
require_relative 'openai'
require 'scout/misc/hook'

module LLM
  module OpenWebUI
    extend Backend

    TAG='openwebui'
    DEFAULT_MODEL='llama3.1'

    def self.client(options, messages = nil)
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

    def self.query(client, messages, tools = [], parameters = {})
      base_url, key, model, method, action = IndiferentHash.process_options client.dup, :base_url, :key, :model, :method, :action
      url = File.join(base_url, action.to_s)

      parameters = parameters.dup

      parameters[:model] ||= model

      parameters[:tools] = self.format_tool_definitions tools if tools && tools.any?
      parameters[:messages] = messages
      parameters[:verify_ssl] = false

      headers = IndiferentHash.setup({"Authorization" => "Bearer #{key}", "Content-Type" => "application/json"})
      response = case method.to_sym
                 when :post
                   RestClient.post(url, parameters.to_json, headers)
                 else
                   raise "Get not supported"
                 end

      JSON.parse(response.body)
    end

    def self.parse_tool_call(info)
      IndiferentHash.setup info
      arguments, name = IndiferentHash.process_options info['function'], :arguments, :name
      arguments = JSON.parse arguments
      id = info[:id] || name + "_" + Misc.digest(arguments)
      {arguments: arguments, id: id, name: name}
    end

    def self.process_response(messages, response, tools, options, &block)
      Log.debug "Response: #{Log.fingerprint response}"

      raise Exception, response["error"] if response["error"]

      message = response.dig("choices", 0, "message")

      tool_calls = response.dig("choices", 0, "tool_calls") ||
        response.dig("choices", 0, "message", "tool_calls")

      if tool_calls && tool_calls.any?
        tool_calls = tool_calls.collect{|tool_call| self.parse_tool_call(tool_call) }
        LLM.process_calls(tools, tool_calls, &block)
      else
       [message]
      end
    end
  end
end

Hook.hook_method(LLM::OpenWebUI, LLM::OpenAI, :format_tool_definitions)
Hook.hook_method(LLM::OpenWebUI, LLM::OpenAI, :format_tool_call)
Hook.hook_method(LLM::OpenWebUI, LLM::OpenAI, :format_tool_output)
Hook.hook_method(LLM::OpenWebUI, LLM::OpenAI, :extra_options)
