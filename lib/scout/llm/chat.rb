#require_relative 'parse'
require_relative 'utils'
require_relative 'tools'
require_relative 'chat/annotation'
require_relative 'chat/parse'
require_relative 'chat/process'

module LLM
  def self.messages(question, role = nil)
    default_role = "user"

    if Array === question
      return question.collect do |q|
        if String === q
          {role: role || default_role, content: q}
        else
          q
        end
      end
    end

    Chat.parse question
  end
  def self.chat(file = [], original = nil)
    original ||= (String === file and Open.exists?(file)) ? file : Path.setup($0.dup)
    caller_lib_dir = Path.caller_lib_dir(nil, 'chats')

    if Path.is_filename? file
      messages = self.messages Open.read(file), file
    else
      messages = self.messages file
    end

    messages = Chat.indiferent messages
    messages = Chat.imports messages, original, caller_lib_dir

    messages = Chat.clear messages
    messages = Chat.clean messages

    messages = Chat.tasks messages
    messages = Chat.jobs messages
    messages = Chat.files messages, original, caller_lib_dir

    Chat.setup messages
  end

  def self.options(...)
    Chat.options(...)
  end

  def self.print(...)
    Chat.print(...)
  end

  def self.tools(...)
    Chat.tools(...)
  end

  def self.associations(...)
    Chat.associations(...)
  end

  def self.purge(...)
    Chat.purge(...)
  end
end

