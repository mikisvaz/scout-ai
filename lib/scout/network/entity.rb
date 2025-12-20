require_relative 'paths'

module Entity
  module Adjacent
    def path_to(adjacency, entities, threshold = nil, max_steps = nil)
      if Array === self
        self.collect{|entity| entity.path_to(adjacency, entities, threshold, max_steps)}
      else
        if adjacency.type == :flat
          max_steps ||= threshold
          Paths.dijkstra(adjacency, self, entities, max_steps)
        else
          Paths.weighted_dijkstra(adjacency, self, entities, threshold, max_steps)
        end
      end
    end

    def random_paths_to(adjacency, l, times, entities)
      if Array === self
        self.inject([]){|acc,entity| acc += entity.random_paths_to(adjacency, l, times, entities)}
      else
        paths = []
        times.times do 
          paths << Paths.random_weighted_dijkstra(adjacency, l, self, entities)
        end
        paths
      end
    end

    # list of neighbours up to a given radius using unweighted adjacency
    # adjacency: Hash[String => Array[String]] or TSV(:flat) treated as adjacency
    # k: maximum number of steps
    # Returns an Array of Arrays (one per entity when self is an array), each
    # containing the reachable entities (as plain values) within k steps
    def neighborhood(adjacency, k)
      if Array === self
        self.collect{|entity| entity.neighborhood(adjacency, k)}
      else
        adj_hash = adjacency.respond_to?(:include?) ? adjacency : adjacency.to_hash
        Paths.neighborhood(adj_hash, self, k)
      end
    end
  end
end

module AssociationItem

  # Dijkstra over a list of AssociationItems, using an optional block to
  # compute edge weights.
  def self.dijkstra(associations, start_node, end_node = nil, threshold = nil, max_steps = nil, &block)
    adjacency = {}

    associations.each do |m|
      s, t, _sep = m.split "~"
      next if s.nil? || t.nil? || s.strip.empty? || t.strip.empty?
      adjacency[s] ||= Set.new
      adjacency[s] << t
      next unless m.undirected
      adjacency[t] ||= Set.new
      adjacency[t] << s
    end

    return nil unless adjacency.include? start_node

    active   = PriorityQueue.new
    distances = Hash.new { 1.0 / 0.0 }
    parents   = Hash.new

    active[start_node] << 0
    best   = 1.0 / 0.0
    found  = false
    node_dist_cache = {}

    until active.empty?
      u        = active.priorities.first
      distance = active.shift
      distances[u] = distance
      path = Paths.extract_path(parents, start_node, u) if parents.key?(u)
      next if max_steps && path && path.length > max_steps 
      next unless adjacency.include?(u) && adjacency[u] && !adjacency[u].empty?
      adjacency[u].each do |v|
        node_dist = node_dist_cache[[u,v]] ||= (block_given? ? block.call(u,v) : 1)
        next if node_dist.nil? || (threshold && node_dist > threshold)
        d = distance + node_dist
        next unless d < distances[v] && d < best # we can't relax this one
        active[v] << d
        distances[v] = d
        parents[v] = u
        if String === end_node ? (end_node == v) : (end_node && end_node.include?(v))
          best = d 
          found = true
        end
      end    
    end

    return nil unless found

    if end_node
      end_node = (end_node & parents.keys).first unless String === end_node
      return nil unless parents.include? end_node
      Paths.extract_path(parents, start_node, end_node)
    else
      parents
    end
  end

  # Connected components from a list of AssociationItems.
  # Returns an Array of Arrays of node identifiers.
  def self.components(associations, undirected: true)
    inc = associations.respond_to?(:incidence) ? associations.incidence : AssociationItem.incidence(associations)

    adjacency = Hash.new { |h,k| h[k] = [] }
    nodes     = Set.new

    inc.each do |src, row|
      # row is a NamedArray; row.keys are targets
      targets = row.keys
      targets.each do |t|
        adjacency[src] << t
        nodes << src << t
        if undirected
          adjacency[t] << src
        end
      end
    end

    components = []
    visited    = Set.new

    nodes.each do |n|
      next if visited.include?(n)
      comp  = []
      queue = [n]
      visited << n
      until queue.empty?
        u = queue.shift
        comp << u
        adjacency[u].each do |v|
          next if visited.include?(v)
          visited << v
          queue << v
        end
      end
      components << comp
    end

    components
  end

  # Degree per node from an AssociationItem list.
  # direction: :out, :in, :both
  def self.degrees(associations, direction: :both)
    inc = associations.respond_to?(:incidence) ? associations.incidence : AssociationItem.incidence(associations)
    deg = Hash.new(0)

    inc.each do |src, row|
      targets = row.keys
      case direction
      when :out
        deg[src] += targets.size
      when :in
        targets.each { |t| deg[t] += 1 }
      when :both
        deg[src] += targets.size
        targets.each { |t| deg[t] += 1 }
      else
        raise ArgumentError, "Unknown direction: #{direction.inspect}"
      end
    end

    deg
  end

  # Induced subgraph: keep only edges whose endpoints are in the given node set.
  def self.subset_by_nodes(associations, nodes)
    node_set = nodes.to_set
    associations.select do |m|
      # Use AssociationItem interface rather than parsing
      s = m.source rescue nil
      t = m.target rescue nil
      next false if s.nil? || t.nil?
      node_set.include?(s) && node_set.include?(t)
    end
  end

  # Neighborhood within k steps inside a fixed subgraph, using unweighted BFS
  # over adjacency built from associations.
  def self.neighborhood(associations, seeds, k)
    inc = associations.respond_to?(:incidence) ? associations.incidence : AssociationItem.incidence(associations)
    adjacency = Hash.new { |h,k| h[k] = [] }

    inc.each do |src, row|
      targets = row.keys
      targets.each do |t|
        adjacency[src] << t
        adjacency[t] << src
      end
    end

    Paths.neighborhood(adjacency, seeds, k)
  end
end
