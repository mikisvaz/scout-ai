require_relative '../parse'
require_relative '../tools'
require_relative '../chat'

module LLM
  module Huggingface

    def self.model(model_options)
      require 'scout/model/python/huggingface'
      require 'scout/model/python/huggingface/causal'

      model, task, checkpoint, dir = IndiferentHash.process_options model_options, :model, :task, :checkpoint, :dir
      model ||= Scout::Config.get(:model, :huggingface, env: 'HUGGINGFACE_MODEL,HF_MODEL')

      CausalModel.new model, dir, model_options
    end

    def self.ask(question, options = {}, &block)
      model_options = IndiferentHash.pull_keys options, :model
      model_options = IndiferentHash.add_defaults model_options, :task => "CausalLM"

      model = self.model model_options

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

      parameters = options.merge(messages: messages)
      Log.debug "Calling client with parameters: #{Log.fingerprint parameters}"

      model.eval(messages)
    end

    def self.embed(text, options = {})
      model_options = IndiferentHash.pull_keys options, :model
      model_options = IndiferentHash.add_defaults model_options, :task => "Embedding"

      model = self.model model_options

      (Array === text) ? model.eval_list(text) : model.eval(text)
    end
  end
end
