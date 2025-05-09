class ScoutModel
  def state_file
    return nil unless directory
    directory.state
  end

  def save_options
    file = directory['options.json']
    file.write(options.to_json)
  end

  def load_options
    file = directory['options.json']
    if file.exists?
      IndiferentHash.setup(JSON.parse(file.read)).merge @options
    else
      @options
    end
  end

  def load_ruby_code(file)
    code = Open.read(file)
    code.sub!(/.*(\sdo\b|{)/, 'Proc.new\1')
    instance_eval code, file
  end

  def load_method(name)
    file = directory[name.to_s]

    if file.exists?
      file.read
    elsif file.set_extension('rb').exists?
      load_ruby_code file.set_extension('rb')
    end
  end

  def save_method(name, value)
    file = directory[name.to_s]

    Log.debug "Saving #{file}"
    case
    when Proc === value
      require 'method_source'
      Open.write(file.set_extension('rb'), value.source)
    when String === train_model
      Open.write(file, @train_model)
    end
  end

  def save
    save_options if @options

    save_method(:eval, @eval) if @eval
    save_method(:eval_list, @eval_list) if @eval_list
    save_method(:extract_features, @extract_features) if @extract_features
    save_method(:extract_features_list, @extract_features_list) if @extract_features_list
    save_method(:post_process, @post_process) if @post_process
    save_method(:post_process_list, @post_process_list) if @post_process_list
    save_method(:train, @train) if @train
    save_method(:init, @init) if @init
    save_method(:load_state, @load_state) if @load_state
    save_method(:save_state, @save_state) if @save_state

    save_state if @state
  end

  def restore
    @eval = load_method :eval
    @eval_list = load_method :eval_list
    @extract_features = load_method :extract_features
    @extract_features_list = load_method :extract_features_list
    @post_process = load_method :post_process
    @post_process_list = load_method :post_process_list
    @train = load_method :train
    @init = load_method :init
    @load_state = load_method :load_state
    @save_state = load_method :save_state
    @options = load_options
  end
end
