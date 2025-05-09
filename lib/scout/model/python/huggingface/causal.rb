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

    train do |texts,labels| 
      model, tokenizer = @state

      if directory
        tsv_file = File.join(directory, 'dataset.tsv')
        checkpoint_dir = File.join(directory, 'checkpoints')
      else
        tmpdir = TmpFile.tmp_file
        Open.mkdir tmpdir
        tsv_file = File.join(tmpdir, 'dataset.tsv')
        checkpoint_dir = File.join(tmpdir, 'checkpoints')
      end

      training_args_obj = ScoutPython.call_method("scout_ai.huggingface.train", :training_args, checkpoint_dir, options[:training_args])
      dataset_file = HuggingfaceModel.text_dataset(tsv_file, texts, labels, options[:class_labels])

      ScoutPython.call_method("scout_ai.huggingface.train", :train_model, model, tokenizer, training_args_obj, dataset_file, options[:class_weights])

      Open.rm_rf tmpdir if tmpdir
    end
  end
end
