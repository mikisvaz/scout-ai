require_relative 'default'
require 'openai'

module LLM
  # OpenAI Responses API backend.
  #
  # This backend uses the default shared implementation in Backend::ClassMethods,
  # which targets the `client.responses.create` endpoint.
  module ResponsesMethods
    # (no overrides for now)
  end

  module Responses
    TAG = 'openai'
    DEFAULT_MODEL = 'gpt-5-nano'

    class << self
      prepend ResponsesMethods
      include Backend::ClassMethods
    end
  end
end
