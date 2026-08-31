require_relative 'default'
require_relative 'openai'
require 'openai'

module LLM
  # GLM Chat Completions backend.
  #
  # Implemented as a module exposing singleton methods (`LLM::OpenAI.ask`, etc).
  # We compose the backend by:
  #   - prepending GLMAIMethods into the singleton class (overrides)
  #   - including Backend::ClassMethods into the singleton class (shared logic)
  module GLMAIMethods
    def format_other(message)
      role = message[:role]

      case role.to_s
      when 'image'
        path = message[:content]
        path = Chat.find_file path
        if Open.remote?(path)
          { role: :user, content: { type: :image_url, image_url: {url: path} } }
        elsif Open.exists?(path)
          path = encode_image(path)
          { role: :user, content: [{ type: :image_url, image_url: {url: path} }] }
        else
          raise "Image does not exist in #{path}"
        end
      when 'pdf'
        path = original_path = message[:content]
        if Open.remote?(path)
          { role: :user, content: { type: :input_file, file_url: path } }
        elsif Open.exists?(path)
          data = encode_pdf(path)
          { role: :user, content: [{ type: :input_file, file_data: data, filename: File.basename(path) }] }
        else
          raise "PDF does not exist in #{path}"
        end
      when 'websearch'
        { role: :tool, content: { type: 'web_search_preview' } }
      when 'previous_response_id'
        nil
      else
        message
      end
    end
  end

  module GLM
    TAG = 'glm'
    DEFAULT_MODEL = 'glm-turbo'

    class << self
      prepend OpenAIMethods
      prepend GLMAIMethods
      include Backend::ClassMethods
    end
  end
end
