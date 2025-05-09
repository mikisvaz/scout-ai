require 'ollama-ai'
require_relative '../parse'
require_relative '../tools'
require_relative '../utils'
require_relative '../chat'

module LLM
  module OLlama
    def self.client(url, key = nil)
      Ollama.new(
        credentials: {
          address: url,
          bearer_token: key
        },
        options: { stream: false, debug: true }
      )
    end


    def self.process_response(responses, &block)
      responses.collect do |response|
        Log.debug "Respose: #{Log.fingerprint response}"

        message = response['message']
        tool_calls = response.dig("tool_calls") ||
          response.dig("message", "tool_calls")

        if tool_calls && tool_calls.any?
          LLM.call_tools tool_calls, &block
        else
          [message]
        end
      end.flatten
    end

    def self.ask(question, options = {}, &block)
      original_options = options.dup

      messages = LLM.chat(question)
      options = options.merge LLM.options messages
      tools = LLM.tools messages
      associations = LLM.associations messages

      client, url, key, model, return_messages, format, stream = IndiferentHash.process_options options,
        :client, :url, :key, :model, :return_messages, :format, :stream,
        stream: false

      if client.nil?
        url ||= Scout::Config.get(:url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        key ||= LLM.get_url_config(:key, url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_KEY')
        client = self.client url, key
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        model ||= LLM.get_url_config(:model, url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_MODEL', default: "mistral")
      end


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

      Log.low "Calling client with parameters #{Log.fingerprint parameters}\n#{LLM.print messages}"

      parameters[:messages] = LLM.tools_to_openai messages
      parameters[:stream] = stream

      response = self.process_response client.chat(parameters), &block

      res = if response.last[:role] == 'function_call_output' 
              response + self.ask(messages + response, original_options.except(:tool_choice).merge(return_messages: true, tools: parameters[:tools]), &block)
            else
              response
            end

      if return_messages
        res
      else
        res.last['content']
      end
    end

    def self.ask_old(question, options = {}, &block)

      client, url, key, model = IndiferentHash.process_options options, :client, :url, :key, :model

      if client.nil?
        url ||= Scout::Config.get(:url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        key ||= LLM.get_url_config(:key, url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_KEY')
        client = self.client url, key
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        model ||= LLM.get_url_config(:model, url, :ollama_ask, :ask, :ollama, env: 'OLLAMA_MODEL', default: "mistral")
      end

      mode  = IndiferentHash.process_options options, :mode

      messages = LLM.messages(question)

      system = []
      prompt = []
      messages.each do |message|
        role, content = message.values_at :role, :content
        if role == 'system'
          system << content
        else
          prompt << content
        end
      end

      case mode
      when :chat, 'chat'
        parameters = options.merge(model: model, messages: messages)
        Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"

        response = client.chat(parameters)
        response.collect do |choice|
          message=choice['message']
          while message["role"] == "assistant" && message["tool_calls"]
            messages << message

            message["tool_calls"].each do |tool_call|
              response_message = LLM.tool_response(tool_call, &block)
              messages << response_message
            end

            parameters[:messages] = messages
            Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
            response = client.chat(parameters)

            message = response[0]['message']
          end

          message["content"]
        end * ""
      else
        parameters = options.merge(model: model, prompt: prompt * "\n", system: system*"\n")
        Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
        response = client.generate(parameters)
        response.collect{|e| e['response']} * ""
      end
    end

    def self.embed(text, options = {})

      client, url, key, model = IndiferentHash.process_options options, :client, :url, :key, :model

      if client.nil?
        url ||= Scout::Config.get(:url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        key ||= LLM.get_url_config(:key, url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_KEY')
        client = self.client url, key
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_URL', default: "http://localhost:11434")
        model ||= LLM.get_url_config(:model, url, :ollama_embed, :embed, :ollama, env: 'OLLAMA_MODEL', default: "mistral")
      end

      parameters = { input: text, model: model }
      Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"
      embeddings = client.request('api/embed', parameters)

      Array === text ? embeddings.first['embeddings'] : embeddings.first['embeddings'].first
    end
  end
end
