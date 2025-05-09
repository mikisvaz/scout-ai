require_relative '../huggingface'

class SequenceClassificationModel < HuggingfaceModel
  def initialize(...)
    super("SequenceClassification", ...)

    self.eval do |features,list|
      model, tokenizer = @state
      texts = list ? list : [features]
      res = ScoutPython.call_method("scout_ai.huggingface.eval", :eval_model, model, tokenizer, texts, options[:locate_tokens])
      list ? res : res[0]
    end

    post_process do |result,list|
      model, tokenizer = @state

      logit_list = list ? list.logits : result

      res = ScoutPython.collect(logit_list) do |logits|
        logits = ScoutPython.numpy2ruby logits
        best_class = logits.index logits.max
        best_class = options[:class_labels][best_class] if options[:class_labels]
        best_class
      end

      list ? res : res[0]
    end
x,
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
