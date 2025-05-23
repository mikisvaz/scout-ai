require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestClass < Test::Unit::TestCase
  def test_eval_chat
    #model = CausalModel.new 'BSC-LT/salamandra-2b-instruct'
    model = CausalModel.new 'mistralai/Mistral-7B-Instruct-v0.3'

    model.init

    net, tok = model.state

    iii model.eval([
      {role: :system, content: "You are a calculator, just reply with the answer"},
      {role: :user, content: " 1 + 2 ="}
    ])
  end

  def test_eval_train
    #model = CausalModel.new 'BSC-LT/salamandra-2b-instruct'
    model = CausalModel.new 'mistralai/Mistral-7B-Instruct-v0.3'

    model.init

    net, tok = model.state

    iii model.eval([
      {role: :system, content: "You are a calculator, just reply with the answer"},
      {role: :user, content: " 1 + 2 ="}
    ])
  end
end

