require 'mcp'

module Workflow
  def mcp(*tasks)
    tasks = tasks.flatten.compact
    tasks = self.tasks.keys if tasks.empty?

    tools = tasks.collect do |task,inputs=nil|
      tool_definition = LLM.task_tool_definition(self, task, inputs)
      description = tool_definition[:description]
      input_schema = tool_definition[:parameters].slice(:properties, :required)
      annotations = tool_definition.slice(:title)
      annotations[:read_only_hint] = true
      annotations[:destructive_hint] = false
      annotations[:idempotent_hint] = true
      annotations[:open_world_hint] = false
      task_name = task.to_s
      workflow = self
      MCP::Tool.define(name: task_name, description: description, input_schema: input_schema, annotations: annotations) do |server_context: nil, **parameters|
        MCP::Tool::Response.new([{type: 'text', text: workflow.job(task_name, parameters).run.to_s}])
      end
    end

    version = "1.0.0"
    MCP::Server.new(
      name: self.name,
      version: version,
      tools: tools
    )
  end

  def mcp_stdio(*tasks)
    server = mcp(*tasks)
    transport = MCP::Server::Transports::StdioTransport.new(server)
    server.transport = transport
    transport.open
  end
end
