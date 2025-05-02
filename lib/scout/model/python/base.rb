require_relative '../base'
require 'scout/python'

class PythonModel < ScoutModel
  def initialize(dir, python_class = nil, python_module = nil, options = nil)
    options, python_module = python_module, :model if options.nil? && Hash === python_module
    python_module = :model if python_module.nil?
    options = {} if options.nil?

    options[:python_class] = python_class if python_class
    options[:python_module] = python_module if python_module

    super(dir, options)

    if options[:python_class]
      self.init do
        ScoutPython.add_path Scout.python.find(:lib)
        ScoutPython.add_path @directory
        ScoutPython.init_scout
        @state = ScoutPython.class_new_obj(@options[:python_module],
                                  @options[:python_class],
                                  **@options.except(:python_class, :python_module))
        @state
      end
    end
  end
end
