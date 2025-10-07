require_relative '../utils'
require 'mcp_client'

module LLM
  def self.mcp_tools(url, options = {})
    type = IndiferentHash.process_options options, :type,
      type: (Open.remote?(url) ? :http : :stdio)

    if url && Open.remote?(url)
      token ||= LLM.get_url_config(:key, url, :mcp)
      options[:headers] = { 'Authorization' => "Bearer #{token}" }
    end

    client = MCPClient.create_client(mcp_server_configs: [options.merge(type: 'http', url: url)])

    tools = client.list_tools

    tool_definitions = IndiferentHash.setup({})
    tools.each do |tool|
      name = tool.name
      description = tool.description
      schema = tool.schema

      function = {
        name: name,
        description: description,
        parameters: schema
      }

      definition = IndiferentHash.setup function.merge(type: 'function', function: function)
      block = Proc.new do |name,params|
        res = tool.server.call_tool(name, params)
        if Hash === res && res['content']
          res = res['content']
        end

        if Array === res and res.length == 1
          res = res.first
        end

        if Hash === res && res['content']
          res = res['content']
        end

        if Hash === res && res['text']
          res = res['text']
        end

        res
      end
      tool_definitions[name] = [block, definition]
    end
    tool_definitions
  end
end
