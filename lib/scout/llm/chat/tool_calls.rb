require 'json'

module Chat
  def self.parse_tool_message(message)
    JSON.parse(message[:content].to_s)
  rescue JSON::ParserError, TypeError
    nil
  end

  # Pair tool calls with their outputs within one persisted chat. This reports
  # structural facts only; use tool_call_status for the common interpretation
  # of exception and exit-status outputs.
  def self.tool_calls(chat, source: nil)
    calls = []
    outputs = Hash.new { |hash, key| hash[key] = [] }

    chat.each_with_index do |message, index|
      role = message[:role].to_s
      next unless %w[function_call mcp_call function_call_output].include?(role)
      info = parse_tool_message(message)
      next unless Hash === info

      call_id = info['id'] || info['call_id'] || info['tool_call_id']
      address = source ? [source.to_s, index] : index

      if role == 'function_call_output'
        outputs[call_id] << { address: address, index: index, message: message, info: info } if call_id
      else
        calls << {
          call_id: call_id,
          name: info['name'] || info.dig('function', 'name'),
          arguments: info['arguments'] || info.dig('function', 'arguments'),
          role: role.to_sym,
          call_address: address,
          call_index: index,
          call_message: message,
          call_info: info
        }
      end
    end

    calls.collect do |call|
      output = call[:call_id] && outputs[call[:call_id]].shift
      call.merge(
        output_address: output && output[:address],
        output_index: output && output[:index],
        output_message: output && output[:message],
        output_info: output && output[:info],
        output: output && output[:info]['content']
      )
    end
  end

  # Common, deliberately separate interpretation of a paired tool output.
  # Missing output is unknown, JSON exceptions fail, and command-style JSON
  # results fail when exit_status is non-zero.
  def self.tool_call_status(call)
    return { success: nil, reason: :missing_output } unless call[:output_info]

    content = call[:output]
    parsed = begin
               JSON.parse(content.to_s)
             rescue JSON::ParserError, TypeError
               nil
             end

    if Hash === parsed && parsed['exception']
      { success: false, reason: :exception, exception: parsed['exception'] }
    elsif Hash === parsed && parsed.include?('exit_status')
      status = parsed['exit_status'].to_i
      { success: status == 0, reason: :exit_status, exit_status: status }
    else
      { success: true, reason: :output }
    end
  end
end
