require_relative 'helpers'
class TorchModel
  def self.get_layer(state, layer = nil)
    state = state.first if Array === state
    if layer.nil?
      state
    else
      layer.split(".").inject(state){|acc,l| PyCall.getattr(acc, l.to_sym) }
    end
  end
  def get_layer(...); TorchModel.get_layer(state, ...); end

  def self.get_weights(state, layer = nil)
    Tensor.setup PyCall.getattr(get_layer(state, layer), :weight)
  end
  def get_weights(...); TorchModel.get_weights(state, ...); end

  def self.freeze(layer, requires_grad=false)
    begin
      PyCall.getattr(layer, :weight).requires_grad = requires_grad
    rescue
    end
    ScoutPython.iterate(layer.children) do |layer|
      freeze(layer, requires_grad)
    end
  end

  def self.freeze_layer(state, layer, requires_grad = false)
    layer = get_layer(state, layer)
    freeze(layer, requires_grad)
  end

  def freeze_layer(...); TorchModel.freeze_layer(state, ...); end
end
