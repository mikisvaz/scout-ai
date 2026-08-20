require 'scout'
require 'aws-sdk-bedrockruntime'
require_relative '../chat'

module LLM
  module Bedrock
    def self.client(region, access_key, secret_key)

      credentials = Aws::Credentials.new(access_key, secret_key) if access_key and secret_key
      options = {}
      options[:region] = region if region
      options[:credentials] = credentials if credentials
      Aws::BedrockRuntime::Client.new(options)
    end

    # ScoutCoder: Bedrock/Anthropic style payloads wrap the individual calls in
    # a content entry ({"type" => "tool_use", "tool_calls" => [...]}). The ask
    # loop used to pass that wrapper itself to LLM.tool_response, which then
    # found neither 'function' nor 'name'/'arguments' and called the tool block
    # with (nil, nil). Unwrap and return the inner tool call entries.
    def self.tool_calls(message)
      [message.dig('content')].compact.flatten.select{|m| m['tool_calls']}.collect{|m| m['tool_calls']}.flatten
    end

    def self.messages_to_prompt(messages)
      system = []
      user = []
      messages.each do |info|
        role, content = info.values_at :role, :content
        if role.to_s == 'system'
          system << content
        else
          user << content
        end
      end
      [system*"\n", user*"\n"]
    end

    def self.ask(question, options = {}, &block)
      client, region, access_key, secret_key, type = IndiferentHash.process_options options, :client, :region, :access_key, :secret_key, :type

      model_options = IndiferentHash.pull_keys options, :model
      model = IndiferentHash.process_options model_options, :model

      if client.nil?
        region ||= Scout::Config.get(:region, :bedrock_ask, :ask, :bedrock, env: 'AWS_REGION')
        access_key ||= LLM.get_url_config(:access_key, nil, :bedrock_ask, :ask, :bedrock, env: 'AWS_ACCESS_KEY_ID')
        secret_key ||= LLM.get_url_config(:secret_key, nil, :bedrock_ask, :ask, :bedrock, env: 'AWS_SECRET_ACCESS_KEY')
        client = self.client(region, access_key, secret_key)
      end

      model ||= Scout::Config.get(:model, :bedrock_ask, :ask, :bedrock, env: 'BEDROCK_MODEL_ID')
      type ||= Scout::Config.get(:type, model, default: :messages)

      role, previous_response_id, tools = IndiferentHash.process_options options, :role, :previous_response_id, :tools
      # ScoutCoder: LLM.parse does not exist (the parser lives in Chat and is
      # exposed as LLM.messages, which delegates to Chat.parse); this call
      # raised NoMethodError on every ask. Use the LLM.messages delegation.
      messages = LLM.messages(question, role)

      case type.to_sym 
      when :messages
        body = model_options.merge({
          system: messages.select{|m| m[:role] == 'system'}.collect{|m| m[:content]}*"\n",
          messages: messages.select{|m| m[:role] == 'user'}
        })
      when :prompt
        system, user = messages_to_prompt messages
        body = model_options.merge({
          prompt: user
        })
      else
        raise "Unkown type #{type}"
      end

      Log.debug "Calling bedrock with model: #{model} parameters: #{Log.fingerprint body}"

      response = client.invoke_model(
        model_id: model,
        content_type: 'application/json',
        body: body.to_json
      )

      result = JSON.parse(response.body.string)
      Log.debug "Response: #{Log.fingerprint result}"
      message = result
      tool_calls = self.tool_calls message

      while tool_calls && tool_calls.any?
        messages << message

        cpus = Scout::Config.get :cpus, :tool_calling, default: 3
        tool_calls.each do |tool_call|
          response_message = LLM.tool_response(tool_call, &block)
          messages << response_message
        end

        body[:messages] = messages.compact
        Log.debug "Calling bedrock with parameters: #{Log.fingerprint body}"
        response = client.invoke_model(
          model_id: model,
          content_type: 'application/json',
          body: body.to_json
        )
        result = JSON.parse(response.body.string)
        Log.debug "Response: #{Log.fingerprint result}"

        message = result
        tool_calls = self.tool_calls message
      end

      message.dig('content').collect{|m|
        m['text']
      } * "\n"
    end

    def self.embed(text, options = {})
      client, region, access_key, secret_key, model = IndiferentHash.process_options options, :client, :region, :access_key, :secret_key, :model

      if client.nil?
        region ||= Scout::Config.get(:region, :bedrock_embed, :embed, :bedrock, env: 'AWS_REGION')
        access_key ||= LLM.get_url_config(:access_key, nil, :bedrock_embed, :embed, :bedrock, env: 'AWS_ACCESS_KEY_ID')
        secret_key ||= LLM.get_url_config(:secret_key, nil, :bedrock_embed, :embed, :bedrock, env: 'AWS_SECRET_ACCESS_KEY')
        client = self.client(region, access_key, secret_key)
      end

      model ||= Scout::Config.get(:model, :bedrock_embed, :embed, :bedrock, env: 'BEDROCK_EMBED_MODEL_ID', default: 'amazon.titan-embed-text-v1')

      response = client.invoke_model(
        model_id: model,
        content_type: 'application/json',
        body: { inputText: text }.to_json
      )

      result = JSON.parse(response.body.string)
      result['embedding']
    end
  end
end
