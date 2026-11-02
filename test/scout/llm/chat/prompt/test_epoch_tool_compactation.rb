require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/chat/prompt/epoch_tool_compactation'

class TestEpochToolCompactation < Test::Unit::TestCase

  # --- fixtures ------------------------------------------------------------
  #
  # Default configuration gives threshold=50, initial_size=20,
  # epochs_per_increase=3, size_increase=10, repeat_increase=10,
  # full=20, base_compacted=80. For a 60-output history with no repeat in
  # the current epoch the schedule is epoch_size=20, new_calls=10, so
  # keep_full_count=30 (reverse 1..30 == forward 31..60) and
  # truncate_to=110 (no drop band): the compact band is reverse 31..60,
  # i.e. forward positions 1..30.

  def call_message(name, arguments, id)
    {
      role: 'function_call',
      content: {name: name, arguments: arguments, id: id}.to_json
    }
  end

  def output_message(id, content, step: nil)
    hash = {name: 'tool', content: content, id: id}
    hash[:step] = step if step

    {role: 'function_call_output', content: hash.to_json}
  end

  def parsed(message)
    Chat.epoch_increment_parse_tool_json(message[:content])
  end

  # 60 adjacent pairs (forward output position = index + 1) plus one
  # leading user message. Oversized interactions sit at forward 10, 15, 20
  # and 25; the sub-threshold pair at forward 1 and the keep-window pair at
  # forward 31 are the untouched-survivor probes.
  def base_history
    messages = [{role: 'user', content: 'start'}]

    60.times do |f|
      forward = f + 1
      id = "call_#{f}"

      case f
      when 9
        name, arguments = 'repeated_tool', {'q' => 'repeat-me'}
        content = 'r' * 500
      when 49
        name, arguments = 'repeated_tool', {'q' => 'repeat-me'}
        content = 'repeat result'
      when 14
        # Output JSON carries no id: paired through the adjacency fallback.
        name, arguments = 'tool_14', {'n' => 14}
        content = 'z' * 500
      when 19
        name, arguments = 'tool_19', {'n' => 19}
        content = 'x' * 5000
      when 24
        name, arguments = 'tool_24',
                          {'cmd' => 'SECRET_MARKER' + ('a' * 600),
                           'path' => '/tmp/f', 'flag' => true}
        content = 'short ok'
      else
        name, arguments = "tool_#{f}", {'n' => f}
        content = "ok #{f}"
      end

      messages << call_message(name, arguments, id)

      if f == 14
        messages << {
          role: 'function_call_output',
          content: {name: 'tool', content: content}.to_json
        }
      elsif f == 19
        messages << output_message(
          id, content,
          step: 'ScoutCoder/help_list_repo_documents/Default_71d0305e'
        )
      else
        messages << output_message(id, content)
      end
    end

    messages
  end

  # Index of the function_call whose parsed id equals `id`; non-JSON
  # messages (user text) are skipped safely.
  def call_index(messages, id)
    messages.index do |m|
      m[:role].to_s == 'function_call' && parsed(m) && parsed(m)['id'] == id
    end
  end

  def records(result)
    result.select { |msg| msg[:compacted] }
  end

  def call_ids(result)
    result.select { |msg| msg[:role].to_s == 'function_call' }
          .collect { |msg| parsed(msg)['id'] }
  end

  def contents_containing(result, text)
    result.select { |msg| msg[:content].to_s.include?(text) }
  end

  # --- 1. pairwise replacement ---------------------------------------------

  def test_pairwise_replacement_removes_both_messages_and_inserts_one_record
    input = base_history
    result = Chat.epoch_tool_compactation(input)

    assert_equal 118, result.length,
                 'one notice + user + 56 pairs + 4 records'
    assert_equal 56,
                 result.count { |m| m[:role].to_s == 'function_call' }
    assert_equal 56,
                 result.count { |m| m[:role].to_s == 'function_call_output' }

    records = records(result)
    assert_equal 4, records.length
    records.each { |r| assert_equal :user, r[:role] }

    # Both messages of each replaced pair are gone; the four ids (plus the
    # blank-id output at forward 15, identified through its call) appear in
    # no surviving tool message.
    %w[call_9 call_14 call_19 call_24].each do |id|
      assert(
        result.none? do |m|
          %w[function_call function_call_output].include?(m[:role].to_s) &&
            m[:content].to_s.include?(id)
        end,
        "#{id} still present in a tool message"
      )
    end

    # Sibling pairs survive with unmodified ids, original names and no
    # 'compacted-' renaming anywhere.
    assert call_ids(result).include?('call_0')
    assert call_ids(result).include?('call_30')

    survivor = result.find do |m|
      m[:role].to_s == 'function_call' && parsed(m)['id'] == 'call_30'
    end
    assert_equal 'tool_30', parsed(survivor)['name']

    assert(
      result.none? { |m| m[:content].to_s.include?('compacted-') },
      'unexpected compacted- renaming'
    )

    # The record stands exactly where the pair's output stood: between the
    # preceding pair's output and the following pair's call.
    record = records.find { |r| r[:content].include?('tool_19') }
    index = result.index(record)

    assert_equal 'call_18', parsed(result[index - 1])['id']
    assert_equal 'call_20', parsed(result[index + 1])['id']
  end

  # --- 2. adjacency of surviving pairs --------------------------------------

  def test_every_surviving_call_is_immediately_followed_by_its_output
    result = Chat.epoch_tool_compactation(base_history)

    result.each_with_index do |msg, index|
      next unless msg[:role].to_s == 'function_call'

      following = result[index + 1]

      assert following, "call at #{index} has no following message"
      assert_equal 'function_call_output', following[:role].to_s,
                   "message after call at #{index} is not its output"
      assert_equal parsed(msg)['id'], parsed(following)['id'],
                   "output after call at #{index} has a different id"

      # No record (or any other message) sits between a call and its own
      # output.
      assert !following[:compacted], 'record inserted inside a pair'
    end
  end

  # --- 3. record contents ----------------------------------------------------

  def test_record_contents_name_id_sizes_and_job_pointer
    result = Chat.epoch_tool_compactation(base_history)
    records = records(result)

    with_step = records.find { |r| r[:content].include?('tool_19') }
    assert with_step, 'record for the oversized-output pair missing'

    text = with_step[:content]

    assert text.include?('Tool: tool_19')
    assert text.include?('Call id: call_19')
    assert_match(/Original sizes: arguments \d+ chars, output 5000 chars/, text)
    assert text.include?(
      'Full output found in job: ScoutCoder/help_list_repo_documents/Default_71d0305e'
    )

    arg_only = records.find { |r| r[:content].include?('tool_24') }
    assert arg_only, 'record for the argument-only pair missing'

    arg_text = arg_only[:content]

    assert_match(/Original sizes: arguments \d+ chars, output 8 chars/, arg_text)
    assert(
      !arg_text.include?('Full output found in job'),
      'job pointer emitted without a step'
    )
    assert_match(/cmd=<omitted, \d+ chars>/, arg_text)
    assert arg_text.include?('path=/tmp/f')
    assert arg_text.include?('flag=true')

    # Exact-or-omitted: neither the secret marker nor any slice of the
    # long value may appear.
    long_value = 'SECRET_MARKER' + ('a' * 600)

    [long_value, long_value[50, 100], 'aaaa'].each do |sample|
      assert(
        !arg_text.include?(sample),
        "record leaks a substring of the long value: #{sample[0, 20].inspect}"
      )
    end

    # No Preview: marker in any record or in the notice.
    assert(
      result.none? { |m| m[:content].to_s.include?('Preview:') },
      'Preview: marker present'
    )
  end

  # --- 4. trigger edges ------------------------------------------------------

  def test_output_exactly_400_chars_is_untouched
    input = base_history
    index = call_index(input, 'call_19')

    output = parsed(input[index + 1])
    output['content'] = 'y' * 400
    input[index + 1] = output_message('call_19', output['content'],
                                      step: output['step'])

    result = Chat.epoch_tool_compactation(input)

    assert(
      call_ids(result).include?('call_19'),
      'pair at the exact 400-char boundary was replaced'
    )
    assert(
      contents_containing(result, 'y' * 400).any? do |m|
        m[:role].to_s == 'function_call_output'
      end,
      '400-char output not kept verbatim'
    )

    # The pair under test is untouched; the other oversized pairs in the
    # fixture may still be replaced.
    assert(
      records(result).none? { |r| r[:content].include?('tool_19') },
      'record emitted for the exactly-400 output'
    )
  end

  def test_output_401_chars_is_replaced
    input = base_history
    index = call_index(input, 'call_19')
    input[index + 1] = output_message('call_19', 'y' * 401)

    result = Chat.epoch_tool_compactation(input)

    assert !call_ids(result).include?('call_19')
    assert records(result).any? { |r| r[:content].include?('tool_19') }
  end

  def test_argument_string_exactly_200_chars_is_untouched
    input = base_history
    index = call_index(input, 'call_19')

    # Replace the pair's oversized output too, so the pair is under test
    # on its argument length alone.
    input[index] = call_message('tool_19', {'v' => 'a' * 200}, 'call_19')
    input[index + 1] = output_message('call_19', 'short ok')

    result = Chat.epoch_tool_compactation(input)

    # The call under test survives with its exact 200-char value; the other
    # oversized pairs of the fixture may still be replaced.
    assert(
      result.any? do |m|
        m[:role].to_s == 'function_call' &&
          parsed(m)['id'] == 'call_19' &&
          parsed(m)['arguments']['v'] == 'a' * 200
      end,
      'call at the exact 200-char argument boundary was replaced'
    )
    assert(
      records(result).none? { |r| r[:content].include?('tool_19') },
      'record emitted for the exactly-200 argument'
    )
  end

  def test_argument_string_201_chars_is_replaced
    input = base_history
    index = call_index(input, 'call_19')
    input[index] = call_message('tool_19', {'v' => 'a' * 201}, 'call_19')

    result = Chat.epoch_tool_compactation(input)

    assert !call_ids(result).include?('call_19')
    assert records(result).any? { |r| r[:content].include?('tool_19') }
  end

  # --- 5. sub-threshold pair in the compact band ------------------------------

  def test_subthreshold_compact_band_pair_is_byte_identical
    input = base_history
    pair_index = call_index(input, 'call_0')

    original_call = input[pair_index]
    original_output = input[pair_index + 1]

    result = Chat.epoch_tool_compactation(input)

    kept_call, kept_output =
      result.each_cons(2).find do |a, b|
        a[:role].to_s == 'function_call' && parsed(a)['id'] == 'call_0'
      end

    assert kept_call, 'sub-threshold compact-band call removed'
    assert_equal 'function_call_output', kept_output[:role].to_s

    assert_equal original_call[:content], kept_call[:content]
    assert_equal original_output[:content], kept_output[:content]
  end

  # --- 6. repeated-call protection -------------------------------------------

  def test_repeated_call_older_instance_replaced_most_recent_kept_full
    input = base_history
    result = Chat.epoch_tool_compactation(input)

    # Older instance (forward 10, reverse 51, compact band, oversized).
    assert(
      records(result).any? do |r|
        r[:content].include?('repeated_tool') && r[:content].include?('call_9')
      end,
      'older repeated instance was not compacted'
    )
    assert !call_ids(result).include?('call_9')

    # Most recent instance (forward 50) survives in full.
    kept_index =
      result.index do |m|
        m[:role].to_s == 'function_call' && parsed(m)['id'] == 'call_49'
      end

    assert kept_index, 'most recent repeated instance removed'
    assert_equal 'repeated_tool', parsed(result[kept_index])['name']
    assert_equal 'repeat result', parsed(result[kept_index + 1])['content']
  end

  # --- 7. orphans and malformed content ---------------------------------------

  def test_orphans_and_malformed_messages_are_untouched
    input = base_history

    malformed_call = {role: 'function_call', content: 'not json at all'}
    malformed_output = {role: 'function_call_output', content: 'also not json'}
    orphan_call = call_message('orphan_tool', {'a' => 1}, 'call_orphan')
    orphan_output = output_message('call_unknown_id', 'orphan output')

    input << {role: 'assistant', content: 'separator'}
    input << malformed_call
    input << malformed_output
    input << orphan_call
    input << orphan_output

    result = Chat.epoch_tool_compactation(input)

    [malformed_call, malformed_output, orphan_call, orphan_output].each do |m|
      kept = result.find do |r|
        r[:role].to_s == m[:role].to_s && r[:content] == m[:content]
      end

      assert kept, "#{m[:role]} message was modified or removed"
    end
  end

  # --- 8. drop band -------------------------------------------------------------

  # 160 outputs: the schedule reaches pinned_total=110, epoch_size=30,
  # new_calls=30, keep_full_count=50, effective_compacted=100,
  # truncate_to=140. Reverse 141..160 == forward 1..20 is dropped.
  def test_interaction_older_than_truncate_to_is_dropped_without_record
    input = [{role: 'user', content: 'start'}]

    160.times do |f|
      id = "call_#{f}"
      input << call_message("tool_#{f}", {'n' => f}, id)
      input << output_message(id, "ok #{f}")
    end

    result = Chat.epoch_tool_compactation(input)

    assert_empty records(result), 'records emitted in the drop band'
    assert_equal 140,
                 result.count { |m| m[:role].to_s == 'function_call' }

    # Dropped ids (call_0 .. call_19) appear in no message; the check must
    # not match call ids by substring (call_1 is a prefix of call_1x).
    (0..19).each do |f|
      assert(
        result.none? { |m| m[:content].to_s =~ /"call_#{f}"/ ||
                            m[:content].to_s.include?("Call id: call_#{f}\n") },
        "call_#{f} from the drop band still present"
      )
    end

    assert(
      call_ids(result).include?('call_20'),
      'first interaction outside the drop band removed'
    )
    assert result.first[:content].start_with?('=== Context Management ===')
  end

  # --- 9. stability -------------------------------------------------------------

  def test_transform_is_deterministic
    first = Chat.epoch_tool_compactation(base_history)
    second = Chat.epoch_tool_compactation(base_history)

    assert_equal first.collect { |m| [m[:role], m[:content]] },
                 second.collect { |m| [m[:role], m[:content]] }
  end

  def test_appending_recent_pair_leaves_earlier_records_and_notice_identical
    base = base_history
    base_result = Chat.epoch_tool_compactation(base)

    grown = base.dup
    grown << call_message('tool_60', {'n' => 60}, 'call_60')
    grown << output_message('call_60', 'ok 60')
    grown_result = Chat.epoch_tool_compactation(grown)

    # The same four interactions are still replaced, and their records are
    # byte-identical, in the same order.
    base_records = records(base_result).collect { |r| r[:content] }
    grown_records = records(grown_result).collect { |r| r[:content] }

    assert_equal base_records, grown_records
    assert_equal 4, grown_records.length

    # The notice is byte-identical (no counters).
    assert_equal base_result.first[:content], grown_result.first[:content]

    # The new pair survives in full.
    assert call_ids(grown_result).include?('call_60')
  end

  # --- 10. notice ----------------------------------------------------------------

  def test_notice_present_fixed_and_prepended_only_when_needed
    result = Chat.epoch_tool_compactation(base_history)

    notice = result.first

    assert_equal :user, notice[:role]
    assert notice[:content].start_with?('=== Context Management ===')
    assert(
      !notice[:content].match(/\d/),
      'notice contains digits (counters would break prefix caching)'
    )
    assert !notice[:compacted]

    # All-short history: nothing replaced or dropped, so no notice.
    quiet = [{role: 'user', content: 'start'}]

    60.times do |f|
      quiet << call_message("tool_#{f}", {'n' => f}, "call_#{f}")
      quiet << output_message("call_#{f}", "ok #{f}")
    end

    quiet_result = Chat.epoch_tool_compactation(quiet)

    assert_empty records(quiet_result)
    assert(
      quiet_result.none? { |m| m[:content].to_s.start_with?('=== Context Management ===') },
      'notice emitted although nothing was replaced or dropped'
    )
  end

  # --- 11. dispatch and default ---------------------------------------------------

  def test_default_context_strategy_pins_the_new_strategy
    assert_equal %w(epoch_tool_compactation inbox),
                 Chat::DEFAULT_CONTEXT_STRATEGY
  end

  def test_prepare_prompt_dispatches_epoch_tool_compactation
    result = Chat.prepare_prompt(base_history, ['epoch_tool_compactation'])

    assert(
      records(result).any? { |r| r[:content].include?('tool_19') },
      'strategy not applied through prepare_prompt'
    )
  end

  def test_shorten_tools_epoch_increment_still_selectable_by_name
    result =
      Chat.prepare_prompt(base_history, ['shorten_tools_epoch_increment'])

    # The old strategy still shortens in place: its CONTEXT-COMPACTED
    # preview marker appears and the tool messages survive as tool
    # messages.
    assert(
      result.any? { |m| m[:content].to_s.include?(Chat::COMPACTATION_MESSAGE) },
      'shorten_tools_epoch_increment no longer produces its preview'
    )
    assert(
      result.any? { |m| m[:role].to_s == 'function_call' },
      'shorten_tools_epoch_increment no longer keeps tool calls'
    )
  end
end
