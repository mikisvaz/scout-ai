require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/model/python/base'
class TestTorchHelpers < Test::Unit::TestCase
  def test_del
    ScoutPython.init_scout
    ScoutPython.pyimport :torch
    batch = [[100.0]]
    tensor = TorchModel.tensor(batch, 'cuda', @dtype)
    tensor.del
  end
end

