require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

# Integration (real infrastructure) copy of test/scout/model/test_base.rb:
# test_R_model runs R code and needs the e1071 package. The trivial
# ScoutModel tests stay unit-side in test/scout/model/test_base.rb.
# Run with `rake test_integration`.
#
# Conditional omission: the probe checks for Rscript and the installed R
# packages before running, and omits with the detected reason otherwise.
class TestClass < Test::Unit::TestCase
  def test_R_model
    omit Availability.r_packages_reason('e1071') unless Availability.r_packages?('e1071')
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
