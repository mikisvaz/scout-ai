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

  def self.database_details_tool_definition(database, undirected, fields)

    if undirected
      properties = {
        associations: {
          type: "array",
          items: { type: :string },
          description: "Associations in the form of source~target or target~source"
        },
        fields: {
          type: "string",
          enum: select_options,
          description: "Limit the response to these detail fields fields"
        },
      }
    else
      properties = {
        associations: {
          type: "array",
          items: { type: :string },
          description: "Associations in the form of source~target"
        },
      }
    end

    if fields.length > 1
      description = <<-EOF
Return details of association as a dictionary object.
Each key is an association and the value is an array with the values of the different fields you asked for, or for all fields otherwise.
The fields are: #{fields * ', '}.
Multiple values may be present and use the charater ';' to separate them.
      EOF
    else
      properties.delete(:fields)
      description = <<-EOF
Return the #{field} of association.
Multiple values may be present and use the charater ';' to separate them.
      EOF
    end

    function = {
        name: database + '_association_details',
        description: description,
        parameters: {
          type: "object",
          properties: properties,
          required: ['associations']
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
      if (fields = knowledge_base.get_database(database).fields).any?
        details_definition = self.database_details_tool_definition(database, undirected, fields)
        tool_definitions.merge(database + '_association_details' => [knowledge_base, details_definition])
      end
    }
  end

  def self.call_knowledge_base(knowledge_base, database, parameters={})
    if database.end_with?('_association_details')
      database = database.sub('_association_details', '')
      associations, fields = IndiferentHash.process_options parameters, :associations, :fields
      index = knowledge_base.get_index(database)
      if fields
        field_pos = fields.collect{|f| index.identify_field f }
        associations.each_with_object({}) do |a,hash|
          values = index[a]
          next if values.nil?
          hash[a] = values.values_at *field_pos
        end
      else
        associations.each_with_object({}) do |a,hash|
          values = index[a]
          next if values.nil?
          hash[a] = values
        end
      end
    else
      entities, reverse = IndiferentHash.process_options parameters, :entities, :reverse
      if reverse
        knowledge_base.parents(database, entities)
      else
        knowledge_base.children(database, entities)
      end
    end
  end
end
