require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

MODEL = 'distilgpt2'

require 'scout-ai'
class TestClass < Test::Unit::TestCase
  # Conditional omission: modules first then local-cache probe (never
  # downloads). model.init needs torch (TorchModel.init_python) and
  # transformers (scout_ai.huggingface.model); training goes through
  # scout_ai.huggingface.data and scout_ai.huggingface.train.next_token,
  # which also import datasets.
  def test_main
    reason = Availability.python_modules_reason('torch', 'transformers', 'datasets', route: :embedded)
    omit "python infrastructure missing: #{reason}" if reason
    omit "huggingface model #{MODEL}: #{Availability.hf_model_reason(MODEL)}" unless Availability.hf_model_cached?(MODEL)

    model = NextTokenModel.new
    train_texts = [
        "say hi, no!",
        "say hi, no no no",
        "say hi, hi ",
        "say hi, hi how are you ",
        "say hi, hi are you good",
    ]

    TmpFile.with_path do |tmp_dir|

      sss 0
      model = NextTokenModel.new MODEL, tmp_dir, training_num_train_epochs: 1000, training_learning_rate: 0.1

      chat = Chat.setup []
      chat.user "say hi"
      ppp model.eval chat

      model.save
      model = PythonModel.new tmp_dir

      chat = Chat.setup []
      chat.user "say hi"
      ppp model.eval chat

      state, tokenizer = model.init
      tokenizer.pad_token = tokenizer.eos_token
      model.add_list train_texts.shuffle
      model.train

      chat = Chat.setup []
      chat.user "say hi"
      ppp model.eval chat

      model.save
      model = PythonModel.new tmp_dir

      chat = Chat.setup []
      chat.user "say hi"
      ppp model.eval chat
    end

  end
end

