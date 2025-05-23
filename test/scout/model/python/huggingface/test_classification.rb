require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestSequenceClassification < Test::Unit::TestCase
  def _test_eval_sequence_classification
    model = SequenceClassificationModel.new 'bert-base-uncased', nil,
      class_labels: %w(Bad Good)

    assert_include ["Bad", "Good"], model.eval("This is dog")
    assert_include ["Bad", "Good"], model.eval_list(["This is dog", "This is cat"]).first
  end

  def test_train_sequence_classification
    model = SequenceClassificationModel.new 'bert-base-uncased', nil,
      class_labels: %w(Bad Good)

    model.init

    10.times do
      model.add "The dog", 'Bad'
      model.add "The cat", 'Good'
    end

    model.train

    assert_equal "Bad", model.eval("This is dog")
    assert_equal "Good", model.eval("This is cat")
  end
end

