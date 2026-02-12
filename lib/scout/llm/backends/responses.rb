require_relative 'default'
require 'openai'

module LLM
  module Responses
    extend Backend
    TAG='openai'
    DEFAULT_MODEL='gpt-5-nano'
  end
end
