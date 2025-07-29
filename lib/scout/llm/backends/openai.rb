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
        if message[:role] == 'image'
          Log.warn "Endpoint 'openai' does not support images, try 'responses': #{message[:content]}"
          next
        else
          message
        end
      end.flatten.compact
    end

    def self.process_response(response, &block)
      Log.debug "Respose: #{Log.fingerprint response}"
      raise Exception, response["error"] if response["error"]

      message = response.dig("choices", 0, "message")
      tool_calls = response.dig("choices", 0, "tool_calls") ||
        response.dig("choices", 0, "message", "tool_calls")

      if tool_calls && tool_calls.any?
        LLM.call_tools tool_calls, &block
      else
        [message]
      end
    end

    def self.ask(question, options = {}, &block)
      original_options = options.dup

      messages = LLM.chat(question)
      options = options.merge LLM.options messages
      tools = LLM.tools messages
      associations = LLM.associations messages

      client, url, key, model, log_errors, return_messages, format, tool_choice_next = IndiferentHash.process_options options,
        :client, :url, :key, :model, :log_errors, :return_messages, :format, :tool_choice_next,
        log_errors: true, tool_choice_next: :none

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

      if tools.any? || associations.any?
        parameters[:tools] = []
        parameters[:tools] += tools.values.collect{|a| a.last } if tools
        parameters[:tools] += associations.values.collect{|a| a.last } if associations
        if not block_given?
          block = Proc.new do |name,parameters|
            IndiferentHash.setup parameters
            if tools[name]
              workflow = tools[name].first
              jobname = parameters.delete :jobname
              workflow.job(name, jobname, parameters).run
            else
              kb = associations[name].first
              entities, reverse = IndiferentHash.process_options parameters, :entities, :reverse
              if reverse
                kb.parents(name, entities)
              else
                kb.children(name, entities)
              end
            end
          end
        end
      end

      messages = self.process_input messages

      Log.low "Calling openai #{url}: #{Log.fingerprint parameters}}"
      Log.debug LLM.print messages

      parameters[:messages] = LLM.tools_to_openai messages

      response = self.process_response client.chat(parameters: parameters), &block

      res = if response.last[:role] == 'function_call_output' 
              response + self.ask(messages + response, original_options.merge(tool_choice: tool_choice_next, return_messages: true, tools: parameters[:tools]), &block)
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
