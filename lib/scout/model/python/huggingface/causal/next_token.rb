require_relative '../causal'

class NextTokenModel < CausalModel
  def initialize(...)
    super(...)

    train do |texts|
      model, tokenizer = @state

      if self.directory
        output_dir = self.directory['output'].find
      else
        output_dir = TmpFile.tmp_file "next_token_model"
      end
      dataset = ScoutPython.call_method(
        "scout_ai.huggingface.data", :list_dataset, tokenizer, texts) 
      ScoutPython.call_method(
        "scout_ai.huggingface.train.next_token", :train_next_token, 
        model:model, tokenizer:tokenizer, dataset:dataset, output_dir:output_dir, **options[:training_args]
      )
    end
  end
end
