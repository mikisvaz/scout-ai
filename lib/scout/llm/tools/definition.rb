module LLM
  # Build one tool definition from its parts, shared by the agent layer
  # (`socialize`, `delegate`, `attachments`) and the workflow task tools
  # (`task_tool_definition`).
  #
  # `name` is the task name exposed to the model (String or Symbol),
  # `description` its description, and `properties` a Hash of
  # `property name => schema fragment`. Fragments are copied verbatim, so an
  # optional property keeps its `default:` key: providers show it to the model
  # and it is preserved on replay.
  #
  # `required` lists the property names that must be supplied (`nil` means
  # none). `defaults` is the replay side-channel consumed by
  # `LLM.process_calls` (tools/call.rb), which merges it into the arguments of
  # a tool call before execution; it is emitted as `parameters[:defaults]`
  # only when truthy, so a nil `defaults` leaves the key absent while an empty
  # Hash is kept as-is.
  #
  # `strict` (default true) sets `additionalProperties: false` so the schema
  # rejects unknown parameters. `envelope` (default true) wraps the payload in
  # the `{type: 'function', function: ...}` envelope used by the agent layer;
  # workflow task tools are emitted bare, as their consumers (backend
  # `format_tool_definitions` and `mcp.rb`) expect.
  def self.tool_definition(name, description, properties,
                           required: nil, defaults: nil, strict: true, envelope: true)
    required = [] if required.nil?
    required = [required] unless Array === required

    parameters = {
      type: 'object',
      properties: properties,
      required: required
    }

    parameters[:defaults] = defaults if defaults
    parameters[:additionalProperties] = false if strict

    function = {
      name: name,
      description: description,
      parameters: parameters
    }

    return IndiferentHash.setup(function) unless envelope

    IndiferentHash.setup(function.merge(type: 'function', function: function))
  end
end
