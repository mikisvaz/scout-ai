require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/model/python/base'
class TestTorchHelpers < Test::Unit::TestCase
  # Conditional omission: the CUDA probe imports torch in a bounded
  # subprocess and checks torch.cuda.is_available(), so this runs whenever a
  # GPU-backed torch is actually present.
  def test_del
    omit 'torch CUDA unavailable (probe: torch.cuda.is_available)' unless Availability.cuda?
    ScoutPython.init_scout
    ScoutPython.pyimport :torch
    batch = [[100.0]]
    tensor = TorchModel.tensor(batch, 'cuda', @dtype)
    tensor.del
  end
end

