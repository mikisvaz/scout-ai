require_relative '../base'

class Decision < ScoutModel

  attr_reader :questions

  def initialize(directory = nil, options = {})
    super
    @questions = options[:questions] || {}
  end

  def eval(input)
    normalize(query(input))
  end

  def eval_list(inputs)
    inputs.map { |input| eval(input) }
  end

  def specification
    { questions: @questions }
  end

  protected

  def query(_input)
    raise NotImplementedError
  end

  def normalize(raw)
    Result.new(raw, self)
  end

  class Result
    attr_reader :value, :model

    def initialize(value, model)
      @value = value
      @model = model
    end
  end
end

