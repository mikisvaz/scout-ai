require 'scout/annotation'
module Chat
  extend Annotation

  def message(role, content)
    self.append({role: role.to_s, content: content})
  end

  def user(content)
    message(:user, content)
  end

  def system(content)
    message(:system, content)
  end

  def assistant(content)
    message(:assistant, content)
  end

  def import(file)
    message(:import, file)
  end

  def import_last(file)
    message(:last, file)
  end

  def file(file)
    message(:file, file)
  end

  def introduce(workflow)
    message(:introduce, workflow)
  end

  def pdf(file)
    message(:pdf, file)
  end


  def directory(directory)
    message(:directory, directory)
  end

  def continue(file)
    message(:continue, file)
  end

  def format(format)
    message(:format, format)
  end

  def tool(*parts)
    content = parts * "\n"
    message(:tool, content)
  end

  def task(workflow, task_name, inputs = {})
    input_str = IndiferentHash.print_options inputs
    content = [workflow, task_name, input_str]*" "
    message(:task, content)
  end

  def inline_task(workflow, task_name, inputs = {})
    input_str = IndiferentHash.print_options inputs
    content = [workflow, task_name, input_str]*" "
    message(:inline_task, content)
  end

  def job(step)
    message(:job, step.path)
  end

  def inline_job(step)
    message(:inline_job, step.path)
  end


  def association(name, path, options = {})
    options_str = IndiferentHash.print_options options
    content = [name, path, options_str]*" "
    message(:association, name)
  end

  def tag(content, name=nil, tag=:file, role=:user)
    self.message role, LLM.tag(tag, content, name)
  end


  def ask(options = {})
    LLM.ask(LLM.chat(self), options)
  end

  def chat(options = {})
    response = ask(options.merge(return_messages: true))
    if Array === response
      self.concat(response)
      final
    else
      self.push({role: :assistant, content: response})
      response
    end
  end

  def json(...)
    self.format :json
    output = ask(...)
    obj = JSON.parse output
    if (Hash === obj) and obj.keys == ['content']
      obj['content']
    else
      obj
    end
  end

  def json_format(format, ...)
    self.format format
    output = ask(...)
    obj = JSON.parse output
    if (Hash === obj) and obj.keys == ['content']
      obj['content']
    else
      obj
    end
  end

  def branch
    self.annotate self.dup
  end

  def option(name, value)
    self.message 'option', [name, value] * " "
  end

  def endpoint(value)
    option :endpoint, value
  end

  def model(value)
    option :model, value
  end

  def image(file)
    self.message :image, file
  end

  # Reporting

  def print
    LLM.print LLM.chat(self)
  end

  def final
    LLM.purge(self).last
  end

  def purge
    Chat.setup(LLM.purge(self))
  end

  def shed
    self.annotate [final]
  end

  def answer
    final[:content]
  end

  # Write and save

  def save(path, force = true)
    path = path.to_s if Symbol === path
    if not (Open.exists?(path) || Path === path || Path.located?(path))
      path = Scout.chats.find[path]
    end
    return if Open.exists?(path) && ! force
    Open.write path, LLM.print(self)
  end

  def write(path, force = true)
    path = path.to_s if Symbol === path
    if not (Open.exists?(path) || Path === path || Path.located?(path))
      path = Scout.chats.find[path]
    end
    return if Open.exists?(path) && ! force
    Open.write path, self.print
  end

  def write_answer(path, force = true)
    path = path.to_s if Symbol === path
    if not (Open.exists?(path) || Path === path || Path.located?(path))
      path = Scout.chats.find[path]
    end
    return if Open.exists?(path) && ! force
    Open.write path, self.answer
  end

  # Image
  def create_image(file, ...)
    base64_image = LLM.image(LLM.chat(self), ...)
    Open.write(file, Base64.decode(file_content), mode: 'wb')
  end
end
