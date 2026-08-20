require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

MODEL = 'distilgpt2'

require 'scout-ai'
class TestClass < Test::Unit::TestCase
  # Conditional omission: the local-cache probe never downloads; training
  # 1000 epochs also needs torch, which is probed the same bounded way.
  def test_main
    omit "huggingface model #{MODEL}: #{Availability.hf_model_reason(MODEL)}" unless Availability.hf_model_cached?(MODEL)
    reason = Availability.python_modules_reason('transformers')
    omit "python infrastructure missing: #{reason}" if reason

    model = NextTokenModel.new
    train_texts = [
        "say hi, no!",
        "say hi, no no no",
        "say hi, hi ",
        "say hi, hi how are you ",
        "say hi, hi are you good",
    ]

    TmpFile.with_path do |tmp_dir|
      iii tmp_dir

      sss 0
      model = NextTokenModel.new MODEL, tmp_dir, training_num_train_epochs: 1000, training_learning_rate: 0.1

      iii :new
      chat = Chat.setup []
      chat.user "say hi"
      ppp model.eval chat

      model.save
      model = PythonModel.new tmp_dir

      iii :load
      chat = Chat.setup []
      chat.user "say hi"
      ppp model.eval chat

      iii :training
      state, tokenizer = model.init
      tokenizer.pad_token = tokenizer.eos_token
      model.add_list train_texts.shuffle
      model.train

      iii :trained
      chat = Chat.setup []
      chat.user "say hi"
      ppp model.eval chat

      model.save
      model = PythonModel.new tmp_dir

      iii :load_again
      chat = Chat.setup []
      chat.user "say hi"
      ppp model.eval chat
    end

  end
end

