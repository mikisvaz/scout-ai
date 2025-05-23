require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout-ai'
class TestClass < Test::Unit::TestCase
  def test_main
    model = NextTokenModel.new 
    train_texts = [
        "say hi, no!",
        "say hi, no no no",
        "say hi, hi ",
        "say hi, hi how are you ",
        "say hi, hi are you good",
    ] 

    model_name = "distilgpt2"  # Replace with your local/other HF Llama checkpoint as needed

    TmpFile.with_path do |tmp_dir|
      iii tmp_dir

      sss 0
      model = NextTokenModel.new model_name, tmp_dir, training_num_train_epochs: 1000, training_learning_rate: 0.1

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

