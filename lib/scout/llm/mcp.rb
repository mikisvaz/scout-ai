require 'mcp'

module Workflow
  def mcp(*tasks)
    tasks = tasks.flatten.compact
    tasks = self.tasks.keys if tasks.empty?

    tools = tasks.collect do |task,inputs=nil|
      tool_definition = LLM.task_tool_definition(self, task, inputs)[:function]
      description = tool_definition[:description]
      input_schema = tool_definition[:parameters].slice(:properties, :required)
      annotations = tool_definition.slice(:title)
      annotations[:read_only_hint] = true
      annotations[:destructive_hint] = false
      annotations[:idempotent_hint] = true
      annotations[:open_world_hint] = false
      MCP::Tool.define(name:task, description: description, input_schema: input_schema, annotations:annotations) do |parameters,context|
        self.job(name, parameters)
      end
    end

    MCP::Server.new(
      name: self.name,
      version: "1.0.0",
      tools: tools
    )
  end
end
