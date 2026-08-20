require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestClass < Test::Unit::TestCase
  MODEL = 'mistralai/Mistral-7B-Instruct-v0.3'

  # Conditional omission: runs only when the model is already in the local
  # huggingface cache. The probe never downloads (see
  # test/support/availability.rb).
  def test_eval_chat
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
