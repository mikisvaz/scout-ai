require 'scout/persist'

Persist.save_drivers[:chat] = proc do |file,content|
  case content
  when LLM::Agent
    new_chat = content.current_chat - content.start_chat
    Open.sensible_write(file, LLM.print(new_chat))
  when Array
    Open.sensible_write(file, LLM.print(content))
  else
    stream = if content.respond_to?(:stream)
               content.stream
             elsif content.respond_to?(:dumper_stream)
               content.dumper_stream
             else
               content
             end
    Open.sensible_write(file, stream)
  end
end

Persist.load_drivers[:chat] = proc do |file| String === file ? LLM.chat(file) : file end

Workflow::TYPE_EXTENSIONS[:chat] = :chat
