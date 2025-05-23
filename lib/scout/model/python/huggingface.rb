require_relative 'torch'

class HuggingfaceModel < TorchModel

  def fix_options
    @options[:training_options] = @options.delete(:training_args) if @options.include?(:training_args)
    @options[:training_options] = @options.delete(:training_kwargs) if @options.include?(:training_kwargs)
    training_args = IndiferentHash.pull_keys(@options, :training) || {}

    @options[:tokenizer_options] = @options.delete(:tokenizer_args) if @options.include?(:tokenizer_args)
    @options[:tokenizer_options] = @options.delete(:tokenizer_kwargs) if @options.include?(:tokenizer_kwargs)
    tokenizer_args = IndiferentHash.pull_keys(@options, :tokenizer) || {}

    @options[:training_args] = training_args
    @options[:tokenizer_args] = tokenizer_args
  end

  def initialize(task=nil, checkpoint=nil, dir = nil, options = {})
    
    super(dir, nil, nil, options)
    
    fix_options

    options[:checkpoint] = checkpoint
    options[:task] = task

    init do 
      TorchModel.init_python
      checkpoint = state_file && File.directory?(state_file) ? state_file : self.options[:checkpoint]

      model = ScoutPython.call_method("scout_ai.huggingface.model", :load_model, 
                                      self.options[:task], checkpoint, 
                                     **(IndiferentHash.setup(
                                       self.options.except(
                                         :training_args, :tokenizer_args, 
                                         :task, :checkpoint, :class_labels, 
                                         :model_options, :return_logits
                                       ))))

      tokenizer_checkpoint = self.options[:tokenizer_args][:checkpoint] || checkpoint

      tokenizer = ScoutPython.call_method("scout_ai.huggingface.model", :load_tokenizer, 
                                         tokenizer_checkpoint, 
                                         **(IndiferentHash.setup(self.options[:tokenizer_args])))

      [model, tokenizer]
    end

    load_state do |state_file|
      model, tokenizer = @state
      TorchModel.init_python
      if state_file && Open.directory?(state_file)
        model.from_pretrained(state_file)
        tokenizer.from_pretrained(state_file)
      end
    end

    save_state do |state_file,state|
      model, tokenizer = @state
      TorchModel.init_python
      if state_file
        model.save_pretrained(state_file)
        tokenizer.save_pretrained(state_file)
      end
    end
    
    #self.eval do |features,list|
    #  model, tokenizer = @state
    #  res = case options[:task]
    #        when "CausalLM"
    #          if not list
    #            list = [features]
    #          end
    #          # Allow for options :chat_template, :chat_template_kwargs, :generation_kwargs
    #          #options[:generation_kwargs] = {max_new_tokens: 1000}
    #          ScoutPython.call_method(
    #            "scout_ai.huggingface.eval", :eval_causal_lm_chat, 
    #            model, tokenizer, list, 
    #            options[:chat_template],
    #            options[:chat_template_kwargs], 
    #            options[:generation_kwargs]
    #          )
    #        else
    #          texts = list ? list : [features]
    #          ScoutPython.call_method("scout_ai.huggingface.eval", :eval_model, model, tokenizer, texts, options[:locate_tokens])
    #        end
    #  list ? res : res[0]
    #end

    #train do |texts,labels| 
    #  model, tokenizer = @state
    #  
    #  if directory
    #    tsv_file = File.join(directory, 'dataset.tsv')
    #    checkpoint_dir = File.join(directory, 'checkpoints')
    #  else
    #    tmpdir = TmpFile.tmp_file
    #    Open.mkdir tmpdir
    #    tsv_file = File.join(tmpdir, 'dataset.tsv')
    #    checkpoint_dir = File.join(tmpdir, 'checkpoints')
    #  end

    #  training_args_obj = ScoutPython.call_method("scout_ai.huggingface.train", :training_args, checkpoint_dir, options[:training_args])
    #  dataset_file = HuggingfaceModel.text_dataset(tsv_file, texts, labels, options[:class_labels])

    #  ScoutPython.call_method("scout_ai.huggingface.train", :train_model, model, tokenizer, training_args_obj, dataset_file, options[:class_weights])

    #  Open.rm_rf tmpdir if tmpdir
    #end
    
  end
end
