require_relative 'process/tools'
require_relative 'process/files'
require_relative 'process/clear'
require_relative 'process/options'

require 'shellwords'

module Chat
  def self.content_tokens(message)
    Shellwords.split(message[:content].strip)
  end

  def self.indiferent(messages)
    messages.collect{|msg| IndiferentHash.setup msg }
  end
end
