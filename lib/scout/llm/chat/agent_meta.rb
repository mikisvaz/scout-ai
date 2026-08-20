module Chat
  # Render the human readable message for a malformed or unusable agent_meta
  # receipt.  This is a plain module function, not a dedicated error class: the
  # raised exception is ScoutException and the structured facts (chat path,
  # output address, call id, tool name, raw entry, reference) always travel in
  # the on_error callback `reference` Hash built by Chat.agent_meta_error_reference.
  def self.agent_meta_error_message(reason, chat_path: nil, output_address: nil, call_id: nil, tool_name: nil, reference: nil)
    message = +"agent_meta receipt #{reason}"
    message << " in chat #{chat_path}" if chat_path
    message << " at output #{Array(output_address).inspect}" unless output_address.nil?
    details = []
    details << "call #{call_id}" if call_id
    details << "tool #{tool_name}" if tool_name
    message << " (#{details * ', '})" unless details.empty?
    message << " reference #{reference}" if reference
    message
  end

  # Delegated-agent inference evidence embedded in function_call_output
  # envelopes.
  #
  # When a tool returns an LLM::Agent, LLM.process_calls serializes the child
  # agent's meta messages as an `agent_meta` array inside the parent output
  # JSON.  These records are portable evidence of child inference events and
  # child producer jobs; they are NOT ordinary parent-chat meta messages and
  # must never be appended to the parent Chat (that would corrupt
  # checkpoint bookkeeping).  Everything in this module is read-only
  # provenance analysis: plain Arrays and Hashes in and out, no wrapper
  # classes, no mutation of the inspected chat.
  #
  # The envelope is generic: any tool output may carry agent_meta, so nothing
  # here special-cases a tool name such as `ask`.

  # One Hash per valid agent_meta entry found across the paired tool outputs
  # of the chat.  Pairing is delegated to Chat.tool_calls; raw text is never
  # scanned with regular expressions.
  #
  # Record shape:
  #
  #   {
  #     origin: :agent_meta,
  #     meta: <IndiferentHash from Chat.parse_meta>,
  #     source: <String path or nil>,
  #     output_address: <as returned by Chat.tool_calls>,
  #     evidence_address: <output_address + [:agent_meta, index]>,
  #     call_id: ...,
  #     tool_name: ...,
  #     agent_meta_index: ...,
  #     raw_message: {role: "meta", content: "..."}
  #   }
  #
  # Malformed data is skipped.  When the caller supplies an Array through the
  # `warnings` keyword, each malformed item appends one warning Hash:
  #
  #   {
  #     origin: :agent_meta,
  #     reason: :not_an_array | :not_a_hash | :invalid_role |
  #             :invalid_content | :unparseable_meta,
  #     source:, output_address:, evidence_address:,
  #     call_id:, tool_name:,
  #     agent_meta_index: (nil when the whole agent_meta value is malformed),
  #     evidence_address: (nil when the index is unknown),
  #     raw_entry: <the malformed item as found>
  #   }
  #
  # Malformed receipt data is never silently reinterpreted as provenance.
  def self.agent_meta_evidence(chat, source: nil, warnings: nil)
    tool_calls(chat, source: source).flat_map do |call|
      output_info = call[:output_info]
      next [] unless Hash === output_info

      # Key presence, not truthiness: an explicit `agent_meta: false` or
      # `agent_meta: nil` is a present-but-malformed receipt and must warn,
      # while an absent key simply has no receipt at all.
      has_agent_meta = output_info.key?('agent_meta') || output_info.key?(:agent_meta)
      next [] unless has_agent_meta
      agent_meta = output_info['agent_meta']
      agent_meta = output_info[:agent_meta] if agent_meta.nil? && output_info.key?(:agent_meta)

      add_warning = lambda do |reason, index, raw_entry|
        return unless Array === warnings
        output_address = call[:output_address]
        evidence_address = if index.nil?
                             nil
                           elsif Array === output_address
                             output_address + [:agent_meta, index]
                           else
                             [output_address, :agent_meta, index]
                           end
        warnings << {
          origin: :agent_meta,
          reason: reason,
          source: source ? source.to_s : nil,
          output_address: output_address,
          evidence_address: evidence_address,
          call_id: call[:call_id],
          tool_name: call[:name],
          agent_meta_index: index,
          raw_entry: raw_entry
        }
        nil
      end

      unless Array === agent_meta
        add_warning.call(:not_an_array, nil, agent_meta)
        next []
      end

      agent_meta.each_with_index.collect do |entry, index|
        unless Hash === entry
          add_warning.call(:not_a_hash, index, entry)
          next nil
        end

        role = entry['role'] || entry[:role]
        content = entry['content'] || entry[:content]

        if role.to_s != 'meta'
          add_warning.call(:invalid_role, index, entry)
          next nil
        end

        unless String === content
          add_warning.call(:invalid_content, index, entry)
          next nil
        end

        meta = parse_meta(content)
        if meta.empty?
          add_warning.call(:unparseable_meta, index, entry)
          next nil
        end

        output_address = call[:output_address]
        # Without a source, Chat.tool_calls reports a bare message index; the
        # receipt address still needs the [:agent_meta, index] suffix.
        evidence_address = if Array === output_address
                             output_address + [:agent_meta, index]
                           else
                             [output_address, :agent_meta, index]
                           end
        {
          origin: :agent_meta,
          meta: meta,
          source: source ? source.to_s : nil,
          output_address: output_address,
          evidence_address: evidence_address,
          call_id: call[:call_id],
          tool_name: call[:name],
          agent_meta_index: index,
          raw_message: { role: role, content: content }
        }
      end.compact
    end
  end

  # All meta evidence for a chat, with a shared `origin` field:
  #
  #   * :chat_meta   - normal persisted `meta:` messages of this chat
  #                    (meta, source, meta_address in [source, index] form,
  #                    message: the raw message);
  #   * :agent_meta  - receipt entries from function_call_output envelopes,
  #                    appended after the local records (see
  #                    Chat.agent_meta_evidence).
  #
  # This is an analysis view only.  Chat#meta, chat.role_messages(:meta), and
  # Chat.token_totals([chat]) keep describing the local Chat and do not absorb
  # delegated receipts.
  #
  # Validation asymmetry, intentional: ordinary persisted `meta:` messages are
  # historical data with no enforced schema, so they stay permissive here (a
  # record is included even when Chat.parse_meta yields an empty Hash) exactly
  # as Chat.trace_chats and Chat.token_totals have always treated them.  A
  # receipt instead has a narrow, generated schema, so malformed receipt
  # entries are skipped with a warning instead of being silently trusted.
  def self.meta_evidence(chat, source: nil, warnings: nil)
    local = chat.each_with_index.select do |message, _index|
      message[:role].to_s == 'meta'
    end.collect do |message, index|
      {
        origin: :chat_meta,
        meta: parse_meta(message[:content].to_s),
        source: source ? source.to_s : nil,
        meta_address: source ? [source.to_s, index] : index,
        message: message
      }
    end

    local + agent_meta_evidence(chat, source: source, warnings: warnings)
  end

  # agent_meta entries that carry a producer job reference (`job=`).  Each
  # returned record is the full evidence record with the reference added at
  # the top level as `job:`, so both the reference value and its evidence
  # location stay together.  Job projection metas are producer references,
  # not token events.
  def self.agent_meta_job_references(chat, source: nil, warnings: nil)
    agent_meta_evidence(chat, source: source, warnings: warnings)
      .select { |record| record[:meta][:job] }
      .collect { |record| record.merge(job: record[:meta][:job]) }
  end

  # Uniform `reference` Hash handed to on_error for agent_meta provenance
  # problems.  Keys are always present; unavailable facts are nil.  It retains
  # the original reference/raw entry, the reason, the output and evidence
  # addresses, the receipt entry index, the call id and tool name when known,
  # and the chat path.
  def self.agent_meta_error_reference(reason:, source:, output_address: nil, evidence_address: nil,
                                      call_id: nil, tool_name: nil, agent_meta_index: nil,
                                      raw_entry: nil, reference: nil)
    {
      reason: reason,
      source: source ? source.to_s : nil,
      output_address: output_address,
      evidence_address: evidence_address,
      call_id: call_id,
      tool_name: tool_name,
      agent_meta_index: agent_meta_index,
      raw_entry: raw_entry,
      reference: reference
    }
  end
end
