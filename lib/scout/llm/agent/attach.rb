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

          # ScoutCoder: bug B1. Two stacked defects made the pdf branch
          # unreachable: (a) the normalization else-branch overwrote an
          # explicit file_type 'pdf' (and every other value) with 'image';
          # (b) the dispatcher below was a bare `case` with no subject, so
          # the first when-list matched unconditionally. Normalize ONLY the
          # 'auto' value (the schema default) and dispatch on the subject.
          file_type = (parameters[:file_type] || 'auto').to_s
          if file_type == 'auto' && path.get_extension.downcase == 'pdf'
            file_type = 'pdf'
          elsif file_type == 'auto'
            file_type = 'image'
          end

          case file_type
          when 'image', 'png', 'jpeg'
            self.image path
          when 'pdf'
            self.pdf path
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

      definition = LLM.tool_definition(task_name, description, properties,
                                       required: [:file])
      @other_options[:tools][task_name] = [block, definition]
    end
  end
end

