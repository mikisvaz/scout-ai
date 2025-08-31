require 'scout/knowledge_base'

module LLM
  def self.database_tool_definition(database, undirected = false, database_description = nil)

    if undirected
      properties = {
        entities: {
          type: "array",
          items: { type: :string },
          description: "Entities for which to find associations"
        },
      }
    else
      properties = {
        entities: {
          type: "array",
          items: { type: :string },
          description: "Source entities in the association, or target entities if 'reverse' is 'true'"
        },
        reverse: {
          type: "boolean",
          description: "Look for targets instead of sources, defaults to 'false'"
        }
      }
    end

    if database_description and not database_description.strip.empty?
      description = <<-EOF
Find associations for a list of entities in database #{database}: #{database_description}
      EOF
    else
      description = <<-EOF
Find associations for a list of entities in database #{database}. 
      EOF
    end

    if undirected
      description += <<-EOF
Returns a list in the format entity~partner.
      EOF
    else
      description += <<-EOF
Returns a list in the format source~target.
      EOF
    end

    function = {
        name: database,
        description: description,
        parameters: {
          type: "object",
          properties: properties,
          required: ['entities']
        }
    }

    IndiferentHash.setup function.merge(type: 'function', function: function)
  end

  def self.knowledge_base_tool_definition(knowledge_base, databases = nil)
    databases ||= knowledge_base.all_databases
    
    databases.inject({}){|tool_definitions,database|
      database_description = knowledge_base.description(database)
      undirected = knowledge_base.undirected(database)
      definition = self.database_tool_definition(database, undirected, database_description)
      tool_definitions.merge(database => [knowledge_base, definition])
    }
  end

  def self.call_knowledge_base(knowledge_base, database, parameters={})
    entities, reverse = IndiferentHash.process_options parameters, :entities, :reverse

    if reverse
      knowledge_base.parents(database, entities)
    else
      knowledge_base.children(database, entities)
    end
  end
end
