require 'scout'
require_relative '../chat'

module LLM
  module Backend
    #{{{ CLIENT

    def client(options)
      url, key, model, log_errors, request_timeout = IndiferentHash.process_options options,
        :url, :key, :model, :log_errors, :request_timeout,
        log_errors: true, request_timeout: 1200

      Object::OpenAI::Client.new(access_token:key, log_errors: log_errors, uri_base: url, request_timeout: request_timeout)
    end

    def client_options(options)
      url, key, model, tag, default_model, log_errors, request_timeout = IndiferentHash.process_options options,
        :url, :key, :model, :tag, :default_model, :log_errors, :request_timeout,
        tag: self::TAG, default_model: self::DEFAULT_MODEL, log_errors: true, request_timeout: 1200

      url ||= Scout::Config.get(:url, "#{tag}_ask", :ask, tag, env: "#{tag.upcase}_URL")
      key ||= LLM.get_url_config(:key, url, "#{tag}_ask", :ask, tag, env: "#{tag.upcase}_KEY")
      model ||= LLM.get_url_config(:model, url, :openai_ask, :ask, :openai, env: "#{tag.upcase}_MODEL", default: default_model)

      {url: url, key: key, model: model}.reject{|k,v| v.nil? }
    end

    def extra_options(options, messages = nil)
      format = IndiferentHash.process_options options, :format

      reasoning_options = IndiferentHash.pull_keys options, :reasoning
      reasoning_options = reasoning_options[:reasoning] if reasoning_options.include?(:reasoning)
      options[:reasoning] = reasoning_options if reasoning_options.any?

      
      text_options = IndiferentHash.pull_keys options, :text
      text_options = reasoning_options[:text] if reasoning_options.include?(:text)
      text_options = text_options[:text] if text_options && text_options.include?(:text)
      options[:text] = text_options if text_options.any?

      options[:text] = process_format format if format

      options
    end

    def prepare_client(options, messages = nil)
      client_options = client_options(options)

      client = IndiferentHash.process_options options, :client

      if client.nil?
        Log.debug "Client options: #{client_options.inspect}"


        client = self.client(options.merge(client_options))
      else
        Log.debug "Reusing client: #{Log.fingerprint client}"
      end

      options[:model] ||= client_options[:model]

      extra_options(options, messages)

      client
    end

    def query(client, messages, tools = [], parameters = {})
      formatted_tools = self.format_tool_definitions tools

      messages = extract_tools(messages, formatted_tools)

      parameters[:tools] = formatted_tools if formatted_tools.any?
      parameters[:input] = messages


      parameters = parameters.except(:previous_response_id) if FalseClass === parameters[:previous_response_id]
      parameters = parameters.except(:previous_response_id) if parameters[:previous_response] == 'false'
      client.responses.create(parameters: parameters.except(:previous_response))
    end

    #{{{ FORMAT

    def process_format(format)
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

    #{{{ MEDIA

    def encode_image(path)
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

    def encode_pdf(path)
      file_content = File.binread(path)  # Replace with your file name
      base64_string = Base64.strict_encode64(file_content)

      "data:application/pdf;base64,#{base64_string}"
    end

    def format_other(message)
      role = message[:role]

      case role.to_s
      when 'image'
        path = message[:content]
        path = Chat.find_file path
        if Open.remote?(path) 
          {role: :user, content: {type: :input_image, image_url: path }}
        elsif Open.exists?(path)
          path = encode_image(path)
          {role: :user, content: [{type: :input_image, image_url: path }]}
        else
          raise "Image does not exist in #{path}"
        end
      when 'pdf'
        path = original_path = message[:content]
        if Open.remote?(path) 
          {role: :user, content: {type: :input_file, file_url: path }}
        elsif Open.exists?(path)
          data = encode_pdf(path)
          {role: :user, content: [{type: :input_file, file_data: data, filename: File.basename(path) }]}
        else
          raise "PDF does not exist in #{path}"
        end
      when 'websearch'
        {role: :tool, content: {type: "web_search_preview"} }
      when 'previous_response_id'
        nil
      else
        message
      end
    end

    #{{{ TOOLS

    def format_tool_definitions(tools)
      return [] if tools.nil?
      tools.values.collect do |obj,definition|
        definition = obj if Hash === obj
        definition

        definition = case definition[:function]
                     when Hash
                       definition.merge(definition.delete :function)
                     else
                       definition
                     end

        definition = IndiferentHash.add_defaults definition, type: :function

        definition[:parameters].delete :defaults if definition[:parameters]

        definition
      end
    end

    def format_tool_call(message)
      info = JSON.parse(message[:content])
      IndiferentHash.setup info
      name = info[:name] || IndiferentHash.dig(info,:function, :name)
      IndiferentHash.setup info
      id = last_id = info[:id] || "fc_#{rand(1000).to_s}"
      id = id.sub(/^fc_/, '')
      arguments_json = (info[:arguments] || {}.to_json)
      arguments_json = arguments_json.to_json unless String === arguments_json

      IndiferentHash.setup({
        "type" => "function_call",
        "status" => "completed",
        "name" => name,
        "arguments" => arguments_json,
        "call_id"=>id,
      })
    end

    def format_tool_output(message, last_id = nil)
      info = JSON.parse(message[:content])
      info = IndiferentHash.setup info
      id = info[:id] || last_id
      raise "No id #{Log.fingerprint message}" if id.nil?
      id = id.sub(/^fc_/, '')
      {                               # append result message
        "type" => "function_call_output",
        "output" => info[:content],
        "call_id"=>id,
      }
    end

    def format_messages(messages)
      messages = IndiferentHash.setup(messages)

      last_id = nil
      messages = messages.collect do |message|
        if message[:role] == 'function_call'
          format_tool_call(message)
        elsif message[:role] == 'function_call_output'
          m = format_tool_output(message, last_id)
          last_id = m[:call_id]
          m
        else
          format_other(message)
        end
      end.flatten.compact
    end

    def extract_tools(messages, tools = [])
      messages.collect do |message|
        if message[:role].to_s == 'tool'
          tools << message[:content]
          nil
        else
          message
        end
      end.compact
    end

    def tools(messages, options)
      tools = options.delete :tools

      case tools
      when Array
        tools = tools.inject({}) do |acc,definition|
          IndiferentHash.setup definition
          name = definition.dig('name') || definition.dig('function', 'name')
          acc.merge(name => definition)
        end if Array === tools
      when nil
        tools = {}
      end

      tools.merge!(LLM.tools messages)
      tools.merge!(LLM.associations messages)

      Log.medium "Tools: #{Log.fingerprint tools.keys}}" if tools

      tools
    end

    #{{{ Processing

    def messages(question, options)
      messages = LLM.chat(question)

      options.merge! LLM.options messages

      if options.delete :websearch
        messages << {role: 'websearch', content: true}
      end

      messages
    end

    def chain_tools(messages, output, tools, options = {}, &block)
      previous_response_id = options[:previous_response_id]

      return output if output === []

      raise "Output format unknown #{output}" unless (Hash === output.last) && output.last.include?(:role)

      output = if output.last[:role] == 'function_call_output'
                 begin
                   case previous_response_id
                   when String
                     output + ask(output, options.except(:tool_choice).merge(return_messages: true, previous_response_id: previous_response_id), &block)
                   else
                     output + ask(messages + output, options.except(:tool_choice).merge(return_messages: true), &block)
                   end
                 rescue Exception
                   #Log.debug 'Tool chaining error. Options: ' + "\n" + JSON.pretty_generate(options.except(:tools))
                   raise $!
                 end
               else
                 output
               end

      output = if output.last[:role] == :previous_response_id
                 output
               elsif previous_response_id
                 previous_response_message = {role: :previous_response_id, content: previous_response_id} if previous_response_id
                 output + [previous_response_message]
               else
                 output
               end
    end

    def parse_tool_call(info)
      arguments, call_id, id, name = IndiferentHash.process_options info.dup, :arguments, :call_id, :id, :name
      arguments = begin
                    JSON.parse arguments 
                  rescue
                    Log.debug 'Parsing call error. Tool call:' + "\n" + JSON.pretty_generate(info) 
                  end if String === arguments
      {name: name, arguments: arguments, id: call_id || id}
    end

    def process_response(messages, response, tools, options, &block)
      Log.debug "Response: #{Log.fingerprint response}"

      output = response['output'].collect do |output|
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
        when 'function_call', 'mcp_call'
          tool_call = self.parse_tool_call(output.dup)
          begin
            LLM.process_calls(tools, [tool_call.dup], &block)
          rescue Exception
            Log.debug 'Processing response error. Response:' + "\n" + JSON.pretty_generate(output) 
            raise $!
          end
        when 'web_search_call'
          next
        else
          eee response
          eee output
          raise 
        end
      end.compact.flatten.collect{|o| IndiferentHash.setup o }

      options[:previous_response_id] = response['id'] unless options[:previous_response].to_s == 'false' || FalseClass === options[:previous_response_id]

      output
    end

    def ask(question, options = {}, &block)
      original_options = options.dup

      return_messages = IndiferentHash.process_options options, :return_messages, return_messages: false

      messages = self.messages question, options

      client = prepare_client options, messages
      formatted_messages = format_messages(messages)
      tools = tools(formatted_messages, options)

      response = begin
                   Log.low "Calling #{self}: #{Log.fingerprint(options.except(:tools))}}"
                   query(client, formatted_messages, tools, options)
                 rescue Exception
                   Log.debug 'Asking error. Options: ' + "\n" + JSON.pretty_generate(options.except(:tools)) 
                   raise $!
                 end

      begin
        output = process_response messages, response, tools, options, &block

        output = chain_tools messages, output, tools, options.merge(client: client, tools: tools)

        if return_messages
          Chat.setup output
        else
          output = LLM.purge(output)
          return '' if output.empty?
          LLM.purge(output).last['content']
        end
      rescue
        #Log.debug 'Response: ' + "\n" + JSON.pretty_generate(response)
        raise $!
      end
    end

    def image(question, options = {}, &block)
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

      messages = process_input messages
      input = []
      parameters = {}
      messages.each do |message|
        input << message
      end
      parameters[:prompt] = LLM.print(input)

      response = client.images.generate(parameters: parameters)

      response
    end

    def embed_query(client, text, parameters = {})
      parameters[:text] = text
      response = client.embeddings(parameters)
      raise response['error']['message'] if response.include? 'error'
      response.dig('data', 0, 'embedding')
    end

    def embed(text, options = {})
      client = prepare_client options
      embed_query client, text, options
    end
  end

end
