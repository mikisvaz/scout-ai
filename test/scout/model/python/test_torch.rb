require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestTorch < Test::Unit::TestCase
  def test_linear
    omit "No python environment" unless Availability.python?
    omit "Torch not installed" unless Availability.python_modules?(:torch)
    model = nil

    TmpFile.with_dir do |dir|

      # Create model

      TorchModel.init_python

      model = TorchModel.new dir
      model.state = ScoutPython.torch.nn.Linear.new(1, 1)
      model.criterion = ScoutPython.torch.nn.MSELoss.new()

      model.extract_features do |f|
        [f]
      end

      model.post_process do |v,list|
        list ? list.collect{|vv| vv.first } :  v.first
      end

      # Train model

      model.add 5.0, [10.0]
      model.add 10.0, [20.0]

      model.options[:training_args][:epochs] = 1000
      model.train

      w = model.get_weights.to_ruby.first.first

      assert w > 1.8
      assert w < 2.2

      # Load the model again

      sss 0
      model.save

      model = ScoutModel.new dir

      # Test model

      y = model.eval_list([100.0, 200.0]).first

      assert(y > 150.0)
      assert(y < 250.0)

      y = model.eval(100.0)

      assert(y > 150.0)
      assert(y < 250.0)

      test = [1.0, 5.0, 10.0, 20.0]
      input_sum = Misc.sum(test)
      sum = Misc.sum(model.eval_list(test))
      assert sum > 0.8 * input_sum * 2
      assert sum < 1.2 * input_sum * 2

      w = TorchModel.get_weights(model.state).to_ruby.first.first

      assert w > 1.8
      assert w < 2.2
    end
  end
end


class TestTorchDefaults < Test::Unit::TestCase
  # Regression test for the @criterion default-wiring bug: the train loop
  # used to assign an SGD optimizer to @criterion (TorchModel.optimizer
  # instead of TorchModel.criterion), so default training failed with
  # "TypeError: Non-callable Python object was given" (doc/Model.md
  # documents MSELoss as the default criterion).
  def test_default_criterion_is_mseloss_and_train_works
    omit "No python environment" unless Availability.python?
    omit "Torch not installed" unless Availability.python_modules?(:torch)

    model = nil

    TmpFile.with_dir do |dir|

      TorchModel.init_python

      model = TorchModel.new dir
      model.state = ScoutPython.torch.nn.Linear.new(1, 1)
      # NOTE: neither criterion nor optimizer is set on purpose; this
      # exercises the default wiring path.

      model.extract_features do |f|
        [f]
      end

      model.post_process do |v,list|
        list ? list.collect{|vv| vv.first } : v.first
      end

      model.add 5.0, [10.0]
      model.add 10.0, [20.0]

      model.options[:training_args][:epochs] = 1000

      model.train

      # The default criterion is the documented MSELoss, not an optimizer
      assert PyCall.getattr(model.criterion, :__class__).to_s.include?('MSELoss')

      w = TorchModel.get_weights(model.state).to_ruby.first.first

      assert w > 1.8
      assert w < 2.2

      y = model.eval(100.0)

      assert y > 150.0
      assert y < 250.0
    end
  end
end
