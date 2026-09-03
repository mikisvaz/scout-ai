module LLM
  class Agent
    
    ATACH_TYPES = %w(auto image pdf png jpeg)
    def attachments
      @other_options[:tools] ||= {}

      task_name = :attach
      block = Proc.new do |_name, parameters|
        begin
          path = Path.setup(parameters[:file]).find
          raise ScoutException, "Path not found: #{path}" unless path.exists?

          file_type = (parameters[:file_type] || 'image').to_s
          if file_type == 'auto' && path.get_extension.downcase == 'pdf'
            file_type = 'pdf'
          else
            file_type = 'image'
          end

          case 
          when 'image', 'png', 'jpeg'
            self.image path
          when 'pdf'
            self.pdf path
          when 'auto'
          else
            raise ScoutException, "Unkown file type: #{parameters[:file_type]}"
          end
        rescue ScoutException => e
          e
        end
      end

      properties = {
        file: {
          type: 'string',
          description: 'Path to the file'
        },
        file_type: {
          type: 'string',
          description: 'File type of the file (e.g image, pdf), auto by default',
          enum: ATACH_TYPES,
          default: 'auto'
        },
      }

      description = <<-EOF
Attach a file to the current chat, supports images and pdfs.
      EOF

      function = {
        name: task_name,
        description: description,
        parameters: {
          type: 'object',
          properties: properties,
          required: [:file],
          additionalProperties: false
        }
      }

      definition = IndiferentHash.setup(function.merge(type: 'function', function: function))
      @other_options[:tools][task_name] = [block, definition]
    end
  end
end

