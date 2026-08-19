require_relative 'process/tools'
require_relative 'process/files'
require_relative 'process/clear'
require_relative 'process/options'
require_relative 'process/meta'

require 'shellwords'

module Chat
  def self.content_tokens(message)
    Shellwords.split(message[:content].strip)
  end

  def self.indiferent(messages)
    messages.collect{|msg| IndiferentHash.setup msg }
  end

  def self.find_role(messages, role)
    messages.select{|m| m[:role].to_sym == role.to_sym }
  end
end
