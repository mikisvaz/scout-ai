require 'scout'
require 'openai'
require_relative '../chat'

module LLM
  module OpenAI

    def self.client(url, key, log_errors = false)
      Object::OpenAI::Client.new(access_token:key, log_errors: log_errors, uri_base: url)
    end

    def self.process_input(messages)
      messages.collect do |message|
        if message[:role] == 'function_call'
          {role: 'assistant', tool_calls: [JSON.parse(message[:content])]}
        elsif message[:role] == 'function_call_output'
          JSON.parse(message[:content])
        else
          message
        end
      end.flatten
    end

    def self.process_response(response, &block)
      Log.debug "Respose: #{Log.fingerprint response}"

      message = response.dig("choices", 0, "message")
      tool_calls = response.dig("choices", 0, "tool_calls") ||
        response.dig("choices", 0, "message", "tool_calls")

      if tool_calls && tool_calls.any?
          tool_calls.collect{|tool_call| 
            response_message = LLM.tool_response(tool_call, &block)
            [
              {role: "function_call", content: tool_call.to_json},
              {role: "function_call_output", content: response_message.to_json},
            ]
          }.flatten
      else
        [message]
      end
    end

    def self.ask(question, options = {}, &block)
      original_options = options.dup

      messages = LLM.chat(question)
      options = options.merge LLM.options messages
      tools = LLM.tools messages

      client, url, key, model, log_errors, return_messages, format = IndiferentHash.process_options options,
        :client, :url, :key, :model, :log_errors, :return_messages, :format,
        log_errors: true

      if client.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :openai, env: 'OPENAI_KEY')
        client = self.client url, key, log_errors
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        model ||= LLM.get_url_config(:model, url, :openai_ask, :ask, :openai, env: 'OPENAI_MODEL', default: "gpt-4.1")
      end

      #role = IndiferentHash.process_options options, :role

      case format.to_sym
      when :json, :json_object
        options[:response_format] = {type: 'json_object'}
      else
        options[:response_format] = {type: format}
      end if format

      parameters = options.merge(model: model)

      if tools.any?
        parameters[:tools] = tools.values.collect{|a| a.last }
        if not block_given?
          block = Proc.new do |name,parameters|
            IndiferentHash.setup parameters
            workflow = tools[name].first
            jobname = parameters.delete :jobname
            workflow.job(name, jobname, parameters).run
          end
        end
      end

      Log.low "Calling client with parameters #{Log.fingerprint parameters}\n#{LLM.print messages}"

      parameters[:messages] = self.process_input messages

      response = self.process_response client.chat(parameters: parameters), &block

      res = if response.last[:role] == 'function_call_output' 
              response + self.ask(messages + response, original_options.except(:tool_choice).merge(return_messages: true))
            else
              response
            end

      if return_messages
        res
      else
        res.last['content']
      end
    end

    def self.embed(text, options = {})

      client, url, key, model, log_errors = IndiferentHash.process_options options, :client, :url, :key, :model, :log_errors

      if client.nil?
        url ||= Scout::Config.get(:url, :openai_embed, :embed, :openai, env: 'OPENAI_URL')
        key ||= LLM.get_url_config(:key, url, :openai_embed, :embed, :openai, env: 'OPENAI_KEY')
        client = self.client url, key, log_errors
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :openai_embed, :embed, :openai, env: 'OPENAI_URL')
        model ||= LLM.get_url_config(:model, url, :openai_embed, :embed, :openai, env: 'OPENAI_MODEL', default: "gpt-3.5-turbo")
      end

      response = client.embeddings(parameters: {input: text, model: model})
      response.dig('data', 0, 'embedding')
    end
  end
end
