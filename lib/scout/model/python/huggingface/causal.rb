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
        options[:generation_kwargs],
        options[:tool_argument]
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

  def chat(messages, tools = nil, runtime_options = {})
    init unless @state
    model, tokenizer = @state

    runtime_options = IndiferentHash.setup(runtime_options)

    ScoutPython.call_method(
      "scout_ai.huggingface.eval", :eval_causal_lm_response,
      model, tokenizer, messages, tools,
      runtime_options[:chat_template] || options[:chat_template],
      runtime_options[:chat_template_kwargs] || options[:chat_template_kwargs],
      runtime_options[:generation_kwargs] || options[:generation_kwargs],
      runtime_options[:tool_argument] || options[:tool_argument],
      runtime_options[:response_parser] || options[:response_parser]
    )
  end
end
