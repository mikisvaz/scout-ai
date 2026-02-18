require_relative 'default'
require 'openai'

module LLM
  module VLLM
    extend Backend
    TAG='vllm'
    DEFAULT_MODEL='vllm'

    def self.parse_tool_call(info)
      arguments, call_id, id, name = IndiferentHash.process_options info.dup, :arguments, :call_id, :id, :name
      name.sub!(/[^a-zA-Z_]+channel[^a-zA-Z_]+[a-zA-Z_]+/, '')
      arguments = begin
                    JSON.parse arguments 
                  rescue
                    Log.debug 'Parsing call error. Tool call:' + "\n" + JSON.pretty_generate(info) 
                  end if String === arguments
      {name: name, arguments: arguments, id: call_id || id}
    end

  end
end
