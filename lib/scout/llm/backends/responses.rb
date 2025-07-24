require_relative 'openai'

module LLM
  module Responses
    def self.encode_image(path)
      path = path.find if Path === path
      file_content = File.binread(path)  # Replace with your file name

      case extension = path.split('.').last.downcase
      when 'jpg', 'jpeg'
        mime = "image/jpeg"
      when 'png'
        mime = "image/png"
      else
        mime = "image/extension"
      end

      base64_image = Base64.strict_encode64(file_content)

      "data:#{mime};base64,#{base64_image}"
    end

    def self.encode_pdf(path)
      file_content = File.binread(path)  # Replace with your file name
      Base64.strict_encode64(file_content)
    end
    def self.tool_response(tool_call, &block)
      tool_call_id = tool_call.dig("id").sub(/^fc_/, '')
      function_name = tool_call.dig("function", "name")
      function_arguments = tool_call.dig("function", "arguments")
      function_arguments = JSON.parse(function_arguments, { symbolize_names: true }) if String === function_arguments
      IndiferentHash.setup function_arguments
      function_response = block.call function_name, function_arguments

      content = case function_response
                when nil
                  "success"
                else
                  function_response
                end
      content = content.to_s if Numeric === content
    end

    def self.tools_to_responses(messages)
      messages.collect do |message|
        if message[:role] == 'function_call'
          info = JSON.parse(message[:content])
          IndiferentHash.setup info
          id = info[:id].sub(/^fc_/, '')
          IndiferentHash.setup({
            "type" => "function_call",
            "status" => "completed",
            "name" => info[:name],
            "arguments" => (info[:arguments] || {}).to_json,
            "call_id"=>"call_#{id}",
          })
        elsif message[:role] == 'function_call_output'
          info = JSON.parse(message[:content])
          IndiferentHash.setup info
          id = info[:id].sub(/^fc_/, '')
          {                               # append result message
            "type" => "function_call_output",
            "output" => info[:content],
            "call_id"=>"call_#{id}",
          }
        else
          message
        end
      end.flatten
    end

    def self.process_response(response, &block)
      Log.debug "Respose: #{Log.fingerprint response}"

      response['output'].collect do |output|
        case output['type']
        when 'message'
          output['content'].collect do |content|
            case content['type']
            when 'output_text'
              IndiferentHash.setup({role: 'assistant', content: content['text']})
            end
          end
        when 'function_call'
          LLM.call_tools [output], &block
        when 'web_search_call'
          next
        else
          eee output
          raise 
        end
      end.compact.flatten
    end

    def self.process_input(messages)
      messages = self.tools_to_responses messages

      messages.collect do |message|
        IndiferentHash.setup(message)
        if message[:role] == 'image'
          path = message[:content]
          if Open.remote?(path) 
            {role: :user, content: {type: :input_image, image_url: path }}
          elsif Open.exists?(path)
            path = self.encode_image(path)
            {role: :user, content: [{type: :input_image, image_url: path }]}
          else
            raise
          end
        elsif message[:role] == 'pdf'
          path = message[:content]
          if Open.remote?(path) 
            {role: :user, content: {type: :input_file, file_url: path }}
          elsif Open.exists?(path)
            data = self.encode_pdf(path)
            {role: :user, content: [{type: :input_file, file_data: data }]}
          else
            raise
          end
        elsif message[:role] == 'websearch'
          {role: :tool, content: {type: "web_search_preview"} }
        else
          message
        end
      end.flatten
    end

    def self.ask(question, options = {}, &block)
      original_options = options.dup

      messages = LLM.chat(question)
      options = options.merge LLM.options messages
      tools = LLM.tools messages
      associations = LLM.associations messages

      client, url, key, model, log_errors, return_messages, format = IndiferentHash.process_options options,
        :client, :url, :key, :model, :log_errors, :return_messages, :format,
        log_errors: true

      if client.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :openai, env: 'OPENAI_KEY')
        client = LLM::OpenAI.client url, key, log_errors
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        model ||= LLM.get_url_config(:model, url, :openai_ask, :ask, :openai, env: 'OPENAI_MODEL', default: "gpt-4.1")
      end

      case format
      when :json, :json_object, "json", "json_object"
        options['text'] = {format: {type: 'json_object'}}
      when String, Symbol
        options['text'] = {format: {type: format}}
      when Hash
        IndiferentHash.setup format

        if format.include?('format')
          options['text'] = format
        elsif format['type'] == 'json_schema'
          options['text'] = {format: format}
        else
          required = format.include?('properties') ? format['properties'].keys : []

          name = format.include?('name') ? format.delete('name') : 'response'

          options['text'] = {format: {name: name,
                                      type: "json_schema",
                                      #additionalProperties: required.empty? ? {type: :string} : false,
                                      required: required,
                                      schema: format,
          }}
        end
      end if format

      parameters = options.merge(model: model)

      if tools.any? || associations.any?
        parameters[:tools] ||= []
        parameters[:tools] += tools.values.collect{|a| a.last } if tools
        parameters[:tools] += associations.values.collect{|a| a.last } if associations
        parameters[:tools] = parameters[:tools].collect{|tool|
          function = tool.delete :function;
          tool.merge function
        }

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

      messages = self.process_input messages
      input = []
      messages.each do |message|
        parameters[:tools] ||= []
        if message[:role].to_s == 'tool'
          parameters[:tools] << message[:content]
        else
          input << message
        end
      end
      parameters[:input] = input

      response = client.responses.create(parameters: parameters)
      response = self.process_response response, &block

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

  end

  def self.image(question, options = {}, &block)
    original_options = options.dup

    messages = LLM.chat(question)
    options = options.merge LLM.options messages
    tools = LLM.tools messages
    associations = LLM.associations messages

    client, url, key, model, log_errors, return_messages, format = IndiferentHash.process_options options,
      :client, :url, :key, :model, :log_errors, :return_messages, :format,
      log_errors: true

    if client.nil?
      url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
      key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :openai, env: 'OPENAI_KEY')
      client = LLM::OpenAI.client url, key, log_errors
    end

    if model.nil?
      url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
      model ||= LLM.get_url_config(:model, url, :openai_ask, :ask, :openai, env: 'OPENAI_MODEL', default: "gpt-image-1")
    end

    messages = self.process_input messages
    input = [] 
    messages.each do |message|
      parameters[:tools] ||= []
      if message[:role].to_s == 'tool'
        parameters[:tools] << message[:content]
      else
        input << message
      end
    end
    parameters[:prompt] = LLM.print(input) 

    response = client.images.generate(parameters: parameters)

    response[0]['b64_json']
  end
end
