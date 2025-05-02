require 'scout/python'

class TorchModel
  module Tensor
    def to_ruby
      ScoutPython.numpy2ruby(self)
    end

    def to_ruby!
      r = self.to_ruby
      self.del
      r
    end

    def length
      PyCall.len(self)
    end

    def self.setup(obj)
      obj.extend Tensor
    end

    def del
      begin
        self.to("cpu")
        self.detach
        self.grad = nil
        self.untyped_storage.resize_ 0
      rescue Exception
        Log.exception $!
      end
      self
    end
  end

  def self.init_python
    ScoutPython.init_scout
    ScoutPython.pyimport :torch
    ScoutPython.pyimport :scout
    ScoutPython.pyimport :scout_ai
    ScoutPython.pyfrom :scout_ai, import: :util
    ScoutPython.pyfrom :torch, import: :nn
  end

  def self.optimizer(model, training_args = {})
    begin
      learning_rate = training_args[:learning_rate] || 0.01
      ScoutPython.torch.optim.SGD.new(model.parameters(), lr: learning_rate)
    end
  end

  def self.criterion(model, training_args = {})
    ScoutPython.torch.nn.MSELoss.new()
  end

  def self.device(model_options)
    case model_options[:device]
    when String, Symbol
      ScoutPython.torch.device(model_options[:device].to_s)
    when nil
      ScoutPython.scout_ai.util.device()
    else
        model_options[:device]
    end
  end

  def self.dtype(model_options)
    case model_options[:dtype]
    when String, Symbol
      ScoutPython.torch.call(model_options[:dtype])
    when nil
      nil
    else
      model_options[:dtype]
    end
  end

  def self.tensor(obj, device, dtype)
    TorchModel::Tensor.setup(ScoutPython.torch.tensor(obj, dtype: dtype, device: device))
  end
end
