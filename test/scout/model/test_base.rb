require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestClass < Test::Unit::TestCase
  def test_trivial_model
    model = ScoutModel.new
    model.eval do |sample,list=nil|
      if list
        list.collect{|sample|
          sample * 2
        }
      else
        sample * 2
      end
    end

    assert_equal 2, model.eval(1)
    assert_equal [2, 4], model.eval_list([1, 2])
  end

  def test_trivial_model_options
    model = ScoutModel.new nil, factor: 4
    model.eval do |sample,list=nil|
      if list
        list.collect{|sample|
          sample * @options[:factor]
        }
      else
        sample * @options[:factor]
      end
    end

    assert_equal 4, model.eval(1)
    assert_equal [4, 8], model.eval_list([1, 2])
  end

  def test_R_model
    require 'rbbt-util'
    require 'rbbt/util/R'

    text =<<-EOF
1 0;1;1
1 1;0;1
1 1;1;1
1 0;1;1
1 1;;1
0 0;1;0
0 1;0;0
0 0;1;0
0 1;0;0
    EOF

    TmpFile.with_file do |dir|
      Open.mkdir dir
      model = ScoutModel.new dir

      model.extract_features do |sample|
        sample.split(";")
      end

      model.train do |list,labels|
        TmpFile.with_file do |feature_file|
          Open.write(feature_file, list.collect{|feats| feats * "\t"} * "\n")
          Open.write(feature_file + '.class', labels * "\n")
          R.run <<-EOF
features = read.table("#{ feature_file }", sep ="\\t", stringsAsFactors=FALSE);
labels = scan("#{ feature_file }.class", what=numeric());
features = cbind(features, class = labels);
rbbt.require('e1071')
model = svm(class ~ ., data = features) 
save(model, file="#{ state_file }");
          EOF
        end
      end

      model.eval do |features|
        TmpFile.with_file do |feature_file|
          TmpFile.with_file do |results|
            Open.write(feature_file, features * "\t")
            R.run <<-EOF
features = read.table("#{ feature_file }", sep ="\\t", stringsAsFactors=FALSE);
library(e1071)
load(file="#{ state_file }")
label = predict(model, features);
cat(label, file="#{results}");
            EOF

            Open.read(results)
          end
        end
      end

      text.split(/\n/).each do |line|
        label, sample = line.split(" ")
        model.add(sample, label)
      end

      model.train

      assert model.eval("1;1;1").to_f > 0.5
      assert model.eval("0;0;0").to_f < 0.5

      model.save

      model = ScoutModel.new dir
      assert model.eval("1;1;1").to_f > 0.5
      assert model.eval("0;0;0").to_f < 0.5

      model.post_process do |result|
        result.to_f < 0.5 ? :bad : :good
      end

      assert_equal :bad, model.eval("0;0;0")
    end
  end
end

