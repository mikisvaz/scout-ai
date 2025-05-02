require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/model/base'

class TestClass < Test::Unit::TestCase
  def test_trivial_model_save

    TmpFile.with_file do |dir|
      model = ScoutModel.new dir

      model.eval do |sample,list=nil|
        if list
          list.collect{|sample|
            sample * 2
          }
        else
          sample * 2
        end
      end

      model.save

      model = ScoutModel.new dir

      assert_equal 2, model.eval(1)
      assert_equal [2, 4], model.eval_list([1, 2])
    end
  end
end

