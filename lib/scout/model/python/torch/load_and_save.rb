class TorchModel
  def self.model_architecture(state_file)
    state_file + '.architecture'
  end

  def self.save_state(state, state_file)
    Log.debug "Saving model state into #{state_file}"
    ScoutPython.torch.save(state.state_dict(), state_file)
  end

  def self.load_state(state, state_file)
    return state unless Open.exists?(state_file)
    Log.debug "Loading model state from #{state_file}"
    state.load_state_dict(ScoutPython.torch.load(state_file))
    state
  end

  def self.save_architecture(state, state_file)
    model_architecture = model_architecture(state_file)
    Log.debug "Saving model architecture into #{model_architecture}"
    ScoutPython.torch.save(state, model_architecture)
  end

  def self.load_architecture(state_file)
    model_architecture = model_architecture(state_file)
    return unless Open.exists?(model_architecture)
    Log.debug "Loading model architecture from #{model_architecture}"
    ScoutPython.torch.load(model_architecture, weights_only: false)
  end

  def reset_state
    @trainer = @state = nil
    Open.rm_rf state_file
    Open.rm_rf TorchModel.model_architecture(state_file)
  end

  def self.save(state_file, state)
    TorchModel.save_architecture(state, state_file)
    TorchModel.save_state(state, state_file)
  end

  def self.load(state_file, state = nil)
    state ||= TorchModel.load_architecture(state_file)
    TorchModel.load_state(state, state_file)
    state
  end
end
