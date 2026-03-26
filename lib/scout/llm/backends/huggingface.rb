require_relative 'default'

module LLM
  module HuggingfaceMethods
    MODEL_OPTION_KEYS = %i[
      task checkpoint dir
      chat_template chat_template_kwargs generation_kwargs
      response_parser tool_argument
      tokenizer_args tokenizer_options
      training_args training_options
      trust_remote_code torch_dtype device_map device
    ]

    def model_options(options = {})
      options = IndiferentHash.setup(options.dup)
      model_options = IndiferentHash.pull_keys(options, :model) || {}

      MODEL_OPTION_KEYS.each do |key|
        model_options[key] = options[key] if options.include?(key)
      end

      model_options[:model] ||= Scout::Config.get(:model, :huggingface, env: 'HUGGINGFACE_MODEL,HF_MODEL')
      model_options
    end

    def model(model_options = {})
      require 'scout/model/python/huggingface'
      require 'scout/model/python/huggingface/causal'

      model_options = IndiferentHash.setup(model_options.dup)
      model_options = IndiferentHash.add_defaults(model_options, task: 'CausalLM')

      model_name = IndiferentHash.process_options(model_options, :model)
      dir = model_options[:dir]

      CausalModel.new model_name, dir, model_options
    end

    def prepare_client(options, messages = nil)
      client = IndiferentHash.process_options(options, :client)

      if client.nil?
        model_options = self.model_options(options)
        Log.debug "Client options: #{model_options.inspect}"

        client = self.model(model_options)
        options[:model] ||= model_options[:model]
      else
        Log.debug "Reusing client: #{Log.fingerprint client}"
      end

      client
    end

    def query(client, messages, tools = [], parameters = {})
      formatted_tools = format_tool_definitions(tools)
      parameters[:generation_kwargs] ||= IndiferentHash.pull_keys parameters, :generation_kwargs
      parameters[:chat_template] ||= IndiferentHash.pull_keys parameters, :chat_template
      parameters = parameters.keys_to_sym 
      response = client.chat(messages, formatted_tools, parameters)
      IndiferentHash.setup(message: response)
    rescue
      Log.debug 'Input parameters: ' + "\n" + JSON.pretty_generate(parameters.except(:tools))
      raise $!
    end

    def format_tool_definitions(tools)
      return [] if tools.nil?

      tools.values.collect do |obj, definition|
        definition = obj if Hash === obj
        definition = IndiferentHash.setup(definition)

        definition = case definition[:function]
                     when Hash
                       definition
                     else
                       { type: :function, function: definition }
                     end

        definition[:function][:parameters].delete(:defaults) if definition.dig(:function, :parameters)

        definition
      end
    end

    def format_tool_call(message)
      tool_call = IndiferentHash.setup(JSON.parse(message[:content]))
      arguments = tool_call.delete('arguments') || tool_call.dig('function', 'arguments') || {}
      arguments = JSON.parse(arguments) rescue arguments if String === arguments
      id = tool_call.delete('call_id') || tool_call.delete('id')
      name = tool_call.delete('name') || tool_call.dig('function', 'name')

      {
        role: 'assistant',
        tool_calls: [IndiferentHash.setup({
          type: 'function',
          id: id,
          function: {
            name: name,
            arguments: arguments
          }
        })]
      }
    end

    def format_tool_output(message, last_id = nil)
      info = IndiferentHash.setup(JSON.parse(message[:content]))
      id = info.delete('call_id') || info.delete('id') || last_id
      name = info.delete('name')
      content = info.delete('content')

      {
        role: 'tool',
        name: name,
        content: content,
        tool_call_id: id,
      }.compact
    end

    def parse_tool_call(info)
      info = IndiferentHash.setup(info)
      function = IndiferentHash.setup(info[:function] || {})

      arguments = function[:arguments] || info[:arguments] || info[:parameters] || {}
      arguments = JSON.parse(arguments) rescue arguments if String === arguments

      name = function[:name] || info[:name]
      id = info[:id] || info[:call_id] || info[:tool_call_id] || (name.to_s + '_' + Misc.digest(arguments.to_json))

      { arguments: arguments, id: id, name: name }
    end

    def process_response(messages, response, tools, options, &block)
      response = IndiferentHash.setup(response.dup)
      message = response[:message] || response
      content = message[:content]
      
      output = []
      output << IndiferentHash.setup(role: :assistant, content: content) if String === content && !content.empty?

      tool_calls = Array(message[:tool_calls]).collect do |tool_call|
        parse_tool_call(tool_call)
      end.compact

      if tool_calls.any?
        output.concat LLM.process_calls(tools, tool_calls, &block)
      elsif output.empty?
        output << IndiferentHash.setup(role: :assistant, content: '') if message.include?(:content)
      end

      output
    end

    def tools(messages, options)
      tools = options.delete :tools

      case tools
      when Array
        tools = tools.inject({}) do |acc, definition|
          IndiferentHash.setup definition
          name = definition.dig('name') || definition.dig('function', 'name')
          acc.merge(name => definition)
        end
      when nil
        tools = {}
      end

      chat_messages = messages.reject do |message|
        message[:role].to_s == 'tool' && (message.include?(:tool_call_id) || message.include?(:name))
      end

      tools.merge!(LLM.tools(chat_messages))
      tools.merge!(LLM.associations(chat_messages))

      Log.high "Tools: #{Log.fingerprint tools.keys}" if tools

      tools
    end

    def reasoning(response, current_meta = nil)
      response = IndiferentHash.setup(response)
      message = IndiferentHash.setup(response[:message] || response)
      reasoning_content = message[:thinking]
      reasoning_content = reasoning_content.gsub("\n", ' ') if String === reasoning_content
      Log.medium "Reasoning:\n" + Log.color(:cyan, reasoning_content) if reasoning_content
      reasoning_content
    end

    def embed(text, options = {})
      model_options = self.model_options(options)
      model_options[:task] = 'Embedding'
      model = self.model(model_options)

      (Array === text) ? model.eval_list(text) : model.eval(text)
    end
  end

  module Huggingface
    TAG = 'huggingface'
    DEFAULT_MODEL = nil

    class << self
      prepend HuggingfaceMethods
      include Backend::ClassMethods
    end
  end
end
