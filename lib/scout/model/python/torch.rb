require_relative 'base'

class TorchModel < PythonModel
  attr_accessor :criterion, :optimizer, :device, :dtype

  def fix_options
    @options[:training_options] = @options.delete(:training_args) if @options.include?(:training_args)
    training_args = IndiferentHash.pull_keys(@options, :training) || {}
    @options[:training_args] = training_args
  end

  def initialize(...)

    super(...)

    fix_options

    load_state do |state_file|
      @state = TorchModel.load(state_file, @state)
    end

    save_state do |state_file,state|
      TorchModel.save(state_file, state)
    end

    train do |features,labels|
      @device ||= TorchModel.device(options)
      @dtype ||= TorchModel.dtype(options)
      @state.to(@device)
      @optimizer ||= TorchModel.optimizer(@state, options[:training_args] || {})
      @criterion ||= TorchModel.optimizer(@state, options[:training_args] || {})

      epochs = options[:training_args][:epochs] || 3
      batch_size = options[:batch_size]
      batch_size ||= options[:training_args][:batch_size]
      batch_size ||= 1

      inputs = TorchModel.tensor(features, @device, @dtype)
      #target = TorchModel.tensor(labels.collect{|v| [v] }, @device, @dtype)
      target = TorchModel.tensor(labels, @device, @dtype)

      Log::ProgressBar.with_bar epochs, :desc => "Training" do |bar|
        epochs.times do |i|
          optimizer.zero_grad()
          outputs = @state.call(inputs)
          outputs = outputs.squeeze() if target.dim() == 1
          loss = criterion.call(outputs, target)
          loss.backward()
          optimizer.step
          Log.debug "Epoch #{i}, loss #{loss}"
          bar.tick
        end
      end
    end

    self.eval do |features,list|
      @device ||= TorchModel.device(options)
      @dtype ||= TorchModel.dtype(options)
      @state.to(@device)
      @state.eval

      list = [features] if features

      batch_size = options[:batch_size]
      batch_size ||= options[:training_args][:batch_size]
      batch_size ||= 1

      res = Misc.chunk(list, batch_size).inject(nil) do |acc,batch|
        tensor = TorchModel.tensor(batch, @device, @dtype)

        loss, chunk_res = @state.call(tensor)
        tensor.del

        chunk_res = loss if chunk_res.nil?

        TorchModel::Tensor.setup(chunk_res)
        chunk_res = chunk_res.to_ruby!

        acc = acc.nil? ? chunk_res : acc + chunk_res

        acc
      end

      features ? res[0] : res
    end
  end
end

require_relative 'torch/helpers'
require_relative 'torch/dataloader'
require_relative 'torch/load_and_save'
require_relative 'torch/introspection'
