require 'paths'

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

    # New: list of neighbours up to a given radius using unweighted adjacency
    # adjacency: Hash[String => Array[String]] or TSV(:flat) treated as adjacency
    # k: maximum number of steps
    # Returns an Array of Arrays (one per entity when self is an array), each
    # containing the reachable entities (as plain values) within k steps
    def neighborhood(adjacency, k)
      if Array === self
        self.collect{|entity| entity.neighborhood(adjacency, k)}
      else
        adj_hash = adjacency.respond_to?(:include?) ? adjacency : adjacency.to_hash
        paths = Paths.neighborhood(adj_hash, self, k)
        paths
      end
    end
  end
end

module AssociationItem

  def self.dijkstra(associations, start_node, end_node = nil, threshold = nil, max_steps = nil, &block)
    adjacency = {}

    associations.each do |m|
      s, t, undirected = m.split "~"
      next m if s.nil? or t.nil? or s.strip.empty? or t.strip.empty?
      adjacency[s] ||= Set.new
      adjacency[s] << t 
      next unless m.undirected
      adjacency[t] ||= Set.new
      adjacency[t] << s  
    end

    return nil unless adjacency.include? start_node

    active = PriorityQueue.new         
    distances = Hash.new { 1.0 / 0.0 } 
    parents = Hash.new                 

    active[start_node] << 0
    best = 1.0 / 0.0
    found = false
    node_dist_cache = {}

    until active.empty?
      u = active.priorities.first
      distance = active.shift
      distances[u] = distance
      path = Paths.extract_path(parents, start_node, u)
      next if path.length > max_steps if max_steps 
      next if not adjacency.include?(u) or (adjacency[u].nil? or adjacency[u].empty? )
      adjacency[u].each do |v|
        node_dist = node_dist_cache[[u,v]] ||= (block_given? ? block.call(u,v) : 1)
        next if node_dist.nil? or (threshold and node_dist > threshold)
        d = distance + node_dist
        next unless d < distances[v] and d < best # we can't relax this one
        active[v] << d
        distances[v] = d
        parents[v] = u
        if (String === end_node ? end_node == v : end_node.include?(v))
          best = d 
          found = true
        end
      end    
    end

    return nil unless found

    if end_node
      end_node = (end_node & parents.keys).first unless String === end_node
      return nil if not parents.include? end_node
      Paths.extract_path(parents, start_node, end_node)
    else
      parents
    end
  end
end
