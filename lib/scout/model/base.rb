require_relative 'util/save'
require_relative 'util/run'

class ScoutModel
  attr_accessor :directory, :options, :state

  def initialize(directory = nil, options={})
    @options = options

    if directory
      directory = Path.setup directory.dup unless Path === directory
      @directory = directory
      restore
    end

    @features = []
    @labels = []
  end
end
