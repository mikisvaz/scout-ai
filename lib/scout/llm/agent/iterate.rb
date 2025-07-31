module LLM
  class Agent

    def iterate(prompt = nil, &block)
      self.endpoint :responses
      self.user prompt if prompt

      obj = self.json_format({
        "$schema": "http://json-schema.org/draft-07/schema#",
        "type": "object",
        "properties": {
          "content": {
            "type": "array",
            "items": { "type": "string" }
          }
        },
        "required": ["content"],
        "additionalProperties": false
      })

      self.option :format, :text

      list = Hash === obj ? obj['content'] : obj

      list.each &block
    end

    def iterate_dictionary(prompt = nil, &block)
      self.endpoint :responses
      self.user prompt if prompt

      dict = self.json_format({
        name: 'dictionary',
        type: 'object',
        properties: {},
        additionalProperties: {type: :string}
      })

      self.option :format, :text

      dict.each &block
    end
  end
end
