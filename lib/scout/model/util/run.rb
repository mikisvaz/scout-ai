class ScoutModel
  def execute(method, *args)
    case method
    when Proc
      instance_exec *args, &method
    when nil
      args.first
    end
  end

  def save_state(&block)
    if block_given?
      @save_state = block
    else
      return @state unless @save_state
      execute @save_state, state_file, @state
    end
  end

  def load_state(&block)
    if block_given?
      @load_state = block
    else
      return @state unless @load_state
      execute @load_state, state_file
    end
  end

  def init(&block)
    return @state if @state
    if block_given?
      @init = block
    else
      @state = execute @init
      load_state
    end
  end

  def eval(sample = nil, &block)
    if block_given?
      @eval = block
    else
      features = extract_features sample

      init unless @state
      result = if @eval.arity == 2

                 execute @eval, features, nil
               else
                 execute @eval, features
               end

      post_process result
    end
  end

  def eval_list(list = nil, &block)
    if block_given?
       @eval_list = block
    else
      list = extract_features_list list

      init unless @state
      result = if @eval_list
                 execute @eval_list, list
               elsif @eval

                 if @eval.arity == 2
                   execute @eval, nil, list
                 else
                   list.collect{|features| execute @eval, features }
                 end
               end

      post_process_list result
    end
  end

  def post_process(result = nil, &block)
    if block_given?
      @post_process = block
    else
      return result if @post_process.nil?

      if @post_process.arity == 2
        execute @post_process, result, nil
      else
        execute @post_process, result
      end
    end
  end

  def post_process_list(list = nil, &block)
    if block_given?
       @post_process_list = block
    else

      if @post_process_list
        execute @post_process_list, list
      elsif @post_process
        if @post_process.arity == 2
          execute @post_process, nil, list
        else
          list.collect{|result| execute @post_process, result }
        end
      else
        return list
      end
    end
  end

  def train(&block)
    if block_given?
      @train = block
    else
      init unless @state
      execute @train, @features, @labels
      save_state
    end
  end

  def extract_features(sample = nil, &block)
    if block_given?
      @extract_features = block
    else
      return sample if @extract_features.nil?

      if @extract_features.arity == 2
        execute @extract_features, sample, nil
      else
        execute @extract_features, sample
      end
    end
  end

  def extract_features_list(list = nil, &block)
    if block_given?
       @extract_features_list = block
    else
      return list if @extract_features.nil?

      if @extract_features_list
        execute @extract_features_list, list
      elsif @extract_features
        if @extract_features.arity == 2
          execute @extract_features, nil, list
        else
          list.collect{|sample| execute @extract_features, sample }
        end
      else
        return list
      end
    end
  end

  def add(sample, label = nil)
    features = extract_features sample
    @features << features
    @labels << label
  end

  def add_list(list, labels = nil)
    if Hash === list
      list.each do |sample,label|
        add sample, label
      end
    else
      list = extract_features_list list
      @features.concat list

      if Hash === labels
        list.each do |sample|
          @labels << labels[sample]
        end
      else
        @labels.concat labels
      end
    end
  end
end
