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

      base64_string = Base64.strict_encode64(file_content)

      "data:#{mime};base64,#{base64_string}"
    end

    def self.encode_pdf(path)
      file_content = File.binread(path)  # Replace with your file name
      base64_string = Base64.strict_encode64(file_content)

      "data:application/pdf;base64,#{base64_string}"
    end

    #def self.tool_response(tool_call, &block)
    #  tool_call_id = tool_call.dig("call_id").sub(/^fc_/, '')
    #  function_name = tool_call.dig("function", "name")
    #  function_arguments = tool_call.dig("function", "arguments")
    #  function_arguments = JSON.parse(function_arguments, { symbolize_names: true }) if String === function_arguments
    #  IndiferentHash.setup function_arguments
    #  function_response = block.call function_name, function_arguments

    #  content = case function_response
    #            when nil
    #              "success"
    #            else
    #              function_response
    #            end
    #  content = content.to_s if Numeric === content
    #end

    def self.tools_to_responses(messages)
      last_id = nil
      messages.collect do |message|
        if message[:role] == 'function_call'
          info = JSON.parse(message[:content])
          IndiferentHash.setup info
          name = info[:name] || IndiferentHash.dig(info,:function, :name)
          IndiferentHash.setup info
          id = last_id = info[:id] || "fc_#{rand(1000).to_s}"
          id = id.sub(/^fc_/, '')
          IndiferentHash.setup({
            "type" => "function_call",
            "status" => "completed",
            "name" => name,
            "arguments" => (info[:arguments] || {}).to_json,
            "call_id"=>id,
          })
        elsif message[:role] == 'function_call_output'
          info = JSON.parse(message[:content])
          IndiferentHash.setup info
          id = info[:id] || last_id
          id = id.sub(/^fc_/, '')
          {                               # append result message
            "type" => "function_call_output",
            "output" => info[:content],
            "call_id"=>id,
          }
        else
          message
        end
      end.flatten
    end

    def self.process_response(response, tools, &block)
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
        when 'reasoning'
          next
        when 'function_call'
          LLM.process_calls(tools, [output], &block)
        when 'web_search_call'
          next
        else
          eee response
          eee output
          raise 
        end
      end.compact.flatten
    end

    def self.process_input(messages)
      messages = self.tools_to_responses messages

      res = []
      messages.each do |message|
        IndiferentHash.setup(message)

        role = message[:role]

        case role.to_s
        when 'image'
          path = message[:content]
          path = LLM.find_file path
          if Open.remote?(path) 
            res << {role: :user, content: {type: :input_image, image_url: path }}
          elsif Open.exists?(path)
            path = self.encode_image(path)
            res << {role: :user, content: [{type: :input_image, image_url: path }]}
          else
            raise "Image does not exist in #{path}"
          end
        when 'pdf'
          path = original_path = message[:content]
          if Open.remote?(path) 
            res << {role: :user, content: {type: :input_file, file_url: path }}
          elsif Open.exists?(path)
            data = self.encode_pdf(path)
            res << {role: :user, content: [{type: :input_file, file_data: data, filename: File.basename(path) }]}
          else
            raise "PDF does not exist in #{path}"
          end
        when 'websearch'
          res << {role: :tool, content: {type: "web_search_preview"} }
        when 'previous_response_id'
          res = [message]
        else
          res << message
        end
      end

      res
    end

    def self.process_format(format)
      case format
      when :json, :json_object, "json", "json_object"
        {format: {type: 'json_object'}}
      when String, Symbol
        {format: {type: format}}
      when Hash
        IndiferentHash.setup format

        if format.include?('format')
          format
        elsif format['type'] == 'json_schema'
          {format: format}
        else

          if ! format.include?('properties')
            format = IndiferentHash.setup({properties: format})
          end

          properties = format['properties']
          new_properties = {}
          properties.each do |name,info|
            case info
            when Symbol, String
              new_properties[name] = {type: info}
            when Array
              new_properties[name] = {type: info[0], description: info[1], default: info[2]}
            else
              new_properties[name] = info
            end
          end
          format['properties'] = new_properties

          required = format['properties'].reject{|p,i| i[:default] }.collect{|p,i| p }

          name = format.include?('name') ? format.delete('name') : 'response'

          format['type'] ||= 'object'
          format[:additionalProperties] = required.empty? ? {type: :string} : false
          format[:required] = required
          {format: {name: name,
                    type: "json_schema",
                    schema: format,
          }}
        end
      end
    end

    def self.ask(question, options = {}, &block)
      original_options = options.dup

      messages = LLM.chat(question)
      options = options.merge LLM.options messages

      client, url, key, model, log_errors, return_messages, format, websearch, previous_response_id, tools, = IndiferentHash.process_options options,
        :client, :url, :key, :model, :log_errors, :return_messages, :format, :websearch, :previous_response_id, :tools,
        log_errors: true

      reasoning_options = IndiferentHash.pull_keys options, :reasoning
      options[:reasoning] = reasoning_options if reasoning_options.any?

      text_options = IndiferentHash.pull_keys options, :text
      options[:text] = text_options if text_options.any?

      if websearch
        messages << {role: 'websearch', content: true}
      end

      if client.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        key ||= LLM.get_url_config(:key, url, :openai_ask, :ask, :openai, env: 'OPENAI_KEY')
        client = LLM::OpenAI.client url, key, log_errors
      end

      if model.nil?
        url ||= Scout::Config.get(:url, :openai_ask, :ask, :openai, env: 'OPENAI_URL')
        model ||= LLM.get_url_config(:model, url, :openai_ask, :ask, :openai, env: 'OPENAI_MODEL', default: "gpt-4.1")
      end

      options['text'] = self.process_format format if format

      parameters = options.merge(model: model)

      case tools
      when Array
        tools = tools.inject({}) do |acc,definition|
          IndiferentHash.setup definition
          name = definition.dig('name') || definition.dig('function', 'name')
          acc.merge(name => definition)
        end
      when nil
        tools = {}
      end

      tools.merge!(LLM.tools messages)
      tools.merge!(LLM.associations messages)

      if tools.any?
        parameters[:tools] = LLM.tool_definitions_to_reponses tools
      end

      parameters['previous_response_id'] = previous_response_id if String === previous_response_id

      Log.low "Calling responses #{url}: #{Log.fingerprint(parameters.except(:tools))}}"
      Log.medium "Tools: #{Log.fingerprint tools.keys}}" if tools

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

      parameters[:input] = LLM.tools_to_openai input

      response = client.responses.create(parameters: parameters)

      Thread.current["previous_response_id"] = previous_response_id = response['id']
      previous_response_message = {role: :previous_response_id, content: previous_response_id}

      response = self.process_response response, tools, &block

      res = if response.last[:role] == 'function_call_output'
              case previous_response_id
              when String
                response + self.ask(response, original_options.except(:tool_choice).merge(return_messages: true, tools: tools, previous_response_id: previous_response_id), &block)
              else
                response + self.ask(messages + response, original_options.except(:tool_choice).merge(return_messages: true, tools: tools), &block)
              end
            else
              response
            end

      if return_messages
        if res.last[:role] == :previous_response_id
          res
        else
          res + [previous_response_message]
        end
      else
        LLM.purge(res).last['content']
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
      parameters = {}
      messages.each do |message|
        input << message
      end
      parameters[:prompt] = LLM.print(input)

      response = client.images.generate(parameters: parameters)

      response
    end
  end
end
