require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestClass < Test::Unit::TestCase
  MODEL = 'mistralai/Mistral-7B-Instruct-v0.3'

  # Conditional omission, modules first then cache (sibling style, see
  # test_classification.rb): model.init runs TorchModel.init_python, which
  # imports torch into the embedded PyCall interpreter
  # (lib/scout/model/python/torch/helpers.rb), and
  # scout_ai.huggingface.model.load_model/load_tokenizer import transformers
  # dynamically (python/scout_ai/huggingface/model.py). The causal eval path
  # does NOT import datasets. Neither probe downloads anything (see
  # test/support/availability.rb).
  def test_eval_chat
    reason = Availability.python_modules_reason('torch', 'transformers', route: :embedded)
    omit "python infrastructure missing: #{reason}" if reason
    omit "huggingface model #{MODEL}: #{Availability.hf_model_reason(MODEL)}" unless Availability.hf_model_cached?(MODEL)
    #model = CausalModel.new 'BSC-LT/salamandra-2b-instruct'
    model = CausalModel.new MODEL

    model.init

    net, tok = model.state

    iii model.eval([
      {role: :system, content: "You are a calculator, just reply with the answer"},
      {role: :user, content: " 1 + 2 ="}
    ])
  end

  def test_eval_train
    reason = Availability.python_modules_reason('torch', 'transformers', route: :embedded)
    omit "python infrastructure missing: #{reason}" if reason
    omit "huggingface model #{MODEL}: #{Availability.hf_model_reason(MODEL)}" unless Availability.hf_model_cached?(MODEL)
    #model = CausalModel.new 'BSC-LT/salamandra-2b-instruct'
    model = CausalModel.new MODEL

    model.init

    net, tok = model.state

    iii model.eval([
      {role: :system, content: "You are a calculator, just reply with the answer"},
      {role: :user, content: " 1 + 2 ="}
    ])
  end
end
