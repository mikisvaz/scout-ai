require 'scout/knowledge_base'
require 'set'

class KnowledgeBase
  # Outward k-hop expansion from seeds over a KB database
  # db: database name (Symbol or String)
  # seeds: Entity or Array of Entities/ids
  # depth: Integer
  # direction: :out, :in, :both
  # filter: optional Proc taking an AssociationItem and returning true/false
  #
  # Returns [visited_nodes, edges], where:
  # - visited_nodes is an Array of identifiers (as returned by AssociationItem.source/target)
  # - edges is an Array of AssociationItems traversed during the expansion
  def radial_expand(db, seeds, depth:, direction: :out, filter: nil)
    current = Array(seeds).compact
    return [[], []] if current.empty?

    visited = Set.new(current)
    edges   = []

    1.upto(depth) do
      next_front = []

      current.each do |entity|
        step_edges = case direction
                     when :out
                       children(db, entity)
                     when :in
                       parents(db, entity)
                     when :both
                       children(db, entity) + parents(db, entity)
                     else
                       raise ArgumentError, "Unknown direction: #{direction.inspect}"
                     end

        step_edges.each do |item|
          next if filter && ! filter.call(item)

          # AssociationItem.source/target return identifiers (or Entities)
          s = item.source
          t = item.target

          # Keep all traversed edges
          edges << item

          # Decide which endpoint is considered the "next" node depending on direction
          targets = case direction
                    when :out then [t]
                    when :in  then [s]
                    when :both then [s, t]
                    end

          targets.each do |node|
            next if visited.include?(node)
            visited << node
            next_front << node
          end
        end
      end

      break if next_front.empty?
      current = next_front
    end

    [visited.to_a, edges.uniq]
  end
end
