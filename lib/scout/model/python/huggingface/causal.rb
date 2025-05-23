require_relative '../huggingface'

class CausalModel < HuggingfaceModel
  def initialize(...)
    super("CausalLM", ...)

    self.eval do |messages,list|
      model, tokenizer = @state
      ScoutPython.call_method(
        "scout_ai.huggingface.eval", :eval_causal_lm_chat, 
        model, tokenizer, messages, 
        options[:chat_template],
        options[:chat_template_kwargs], 
        options[:generation_kwargs]
      )
    end

    train do |pairs,labels|
      # data: array of [response, reward] or [prompt, response, reward]
      model, tokenizer = @state

      ScoutPython.call_method(
        "scout_ai.huggingface.rlhf", :train_rlhf, 
        self.state_file, tokenizer, pairs, labels, options[:rlhf_config]
      )
      load_state
    end
  end
end
