require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/integration/), '').sub(/test_(.*)\.rb/,'\1')

class TestDecisionJevIntegration < Test::Unit::TestCase

  def setup
    omit "Set TYPESAFE_API_KEY to run Jev integration tests" unless
      Scout::Config :key, :jev, env:"TYPESAFE_API_KEY"
  end

  def test_evaluate_real_case
    decision = Decision::Jev.new(
      model: ENV.fetch("JEV_MODEL", "jev-latest"),
      questions: {
        "is_bug" => {
          "type" => "noul",
          "instructions" =>
            "Does the report describe a software defect rather than a " \
            "configuration problem, user misunderstanding, or feature request?",
          "criteria" => {
            "true" => "The described behavior is a software defect.",
            "false" => "The behavior is better explained by something else."
          }
        },

        "category" => {
          "type" => "choice",
          "instructions" => "What is the primary category of the report?",
          "criteria" => {
            "bug" => "An existing feature behaves incorrectly.",
            "configuration" => "The software is functioning but configured incorrectly.",
            "feature_request" => "The user is asking for new functionality.",
            "usage_question" => "The user needs help using existing functionality."
          }
        },

        "severity" => {
          "type" => "score",
          "instructions" => "How severe is the reported problem?",
          "criteria" => [
            "Minor: inconvenience with an easy workaround",
            "Moderate: substantially impairs normal use",
            "Major: an important function is unusable",
            "Critical: causes data loss, security impact, or widespread outage"
          ]
        }
      }
    )

    state = {
      "report" => <<~TEXT,
        After upgrading to version 4.2, importing a TSV file with a quoted
        field containing a newline causes the application to crash.

        The same file imported successfully in version 4.1.
        There is no workaround except removing the affected records or
        converting the file to another format first.
      TEXT

      "environment" => {
        "version" => "4.2",
        "previous_version" => "4.1"
      }
    }

    result = decision.eval(state)

    # ---- General response contract --------------------------------------

    assert_kind_of Hash, result.value

    answers = result.value.fetch("answers")
    usage = result.value.fetch("usage")

    assert_kind_of Hash, answers
    assert_kind_of Hash, usage

    assert_operator usage.fetch("input_tokens"), :>, 0
    assert_operator usage.fetch("output_tokens"), :>=, 0

    # ---- Noul ------------------------------------------------------------

    is_bug = answers.fetch("is_bug")

    assert_equal "noul", is_bug.fetch("type")

    probability = is_bug.fetch("noul")

    assert_kind_of Numeric, probability
    assert_operator probability, :>=, 0.0
    assert_operator probability, :<=, 1.0

    # ---- Choice ----------------------------------------------------------

    category = answers.fetch("category")

    assert_equal "choice", category.fetch("type")

    choice = category.fetch("choice")
    probabilities = category.fetch("probabilities")
    confidence = category.fetch("confidence")

    assert_includes(
      %w[bug configuration feature_request usage_question],
      choice
    )

    assert_equal(
      %w[bug configuration feature_request usage_question].sort,
      probabilities.keys.sort
    )

    assert_in_delta 1.0, probabilities.values.sum, 1e-6

    assert_operator confidence, :>=, 0.0
    assert_operator confidence, :<=, 1.0

    # ---- Score -----------------------------------------------------------

    severity = answers.fetch("severity")

    assert_equal "score", severity.fetch("type")

    score = severity.fetch("score")
    score_probabilities = severity.fetch("probabilities")

    assert_kind_of Numeric, score
    assert_equal 4, score_probabilities.length

    assert_in_delta 1.0, score_probabilities.values.sum, 1e-6

    # Useful while developing the integration.
    puts
    puts "Jev model: #{result.value.fetch("model")}"
    puts "Bug probability: #{probability}"
    puts "Category: #{choice}"
    puts "Category probabilities: #{probabilities.inspect}"
    puts "Category confidence: #{confidence}"
    puts "Severity score: #{score}"
    puts "Severity probabilities: #{score_probabilities.inspect}"
    puts "Usage: #{usage.inspect}"
  end
end

