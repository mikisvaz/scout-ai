require 'fc'

module Paths

  def self.dijkstra(adjacency, start_node, end_node = nil, max_steps = nil)

    return nil unless adjacency.include? start_node

    case end_node
    when String
      return nil unless adjacency.values.flatten.include? end_node
    when Array
      return nil unless (adjacency.values.flatten & end_node).any?
    end

    active = FastContainers::PriorityQueue.new(:min)
    distances = Hash.new { 1.0 / 0.0 } 
    parents = Hash.new                 

    active.push(start_node, 0)
    best = 1.0 / 0.0
    until active.empty?
      u = active.top
      distance = active.top_key
      active.pop

      distances[u] = distance
      d = distance + 1
      path = extract_path(parents, start_node, u)
      next if path.length > max_steps if max_steps 
      adjacency[u].each do |v|
        next unless d < distances[v] and d < best # we can't relax this one
        best = d if (String === end_node ? end_node == v : end_node.include?(v))
        active.push(v,d) if adjacency.include? v
        distances[v] = d
        parents[v] = u
      end    
    end

    if end_node
      end_node = end_node.select{|n| parents.keys.include? n}.first unless String === end_node
      return nil if not parents.include? end_node
      extract_path(parents, start_node, end_node)
    else
      parents
    end
  end

  def self.extract_path(parents, start_node, end_node)
    path = [end_node]
    while not path.last === start_node
      path << parents[path.last]
    end
    path
  end

  def self.weighted_dijkstra(adjacency, start_node, end_node = nil, threshold = nil, max_steps = nil)
    return nil unless adjacency.include? start_node

    active = FastContainers::PriorityQueue.new(:min)
    distances = Hash.new { 1.0 / 0.0 } 
    parents = Hash.new                 

    active.push(start_node, 0)
    best = 1.0 / 0.0
    found = false
    until active.empty?
      u = active.top
      distance = active.top_key
      active.pop
      distances[u] = distance
      path = extract_path(parents, start_node, u)
      next if path.length > max_steps if max_steps 
      next if not adjacency.include?(u) or (adjacency[u].nil? or adjacency[u].empty? )
      NamedArray.zip_fields(adjacency[u]).each do |v,node_dist|
        node_dist = node_dist.to_f
        next if node_dist.nil? or (threshold and node_dist > threshold)
        d = distance + node_dist
        next unless d < distances[v] and d < best # we can't relax this one
        active.push(v, d)
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
      extract_path(parents, start_node, end_node)
    else
      parents
    end
  end

  def self.random_weighted_dijkstra(adjacency, l, start_node, end_node = nil)
    return nil unless adjacency.include? start_node

    active = PriorityQueue.new         
    distances = Hash.new { 1.0 / 0.0 } 
    parents = Hash.new                 

    active[start_node] << 0
    best = 1.0 / 0.0
    until active.empty?
      u = active.priorities.first
      distance = active.shift
      distances[u] = distance
      next if not adjacency.include?(u) or adjacency[u].nil? or adjacency[u].empty?
      NamedArray.zip_fields(adjacency[u]).each do |v,node_dist|
        next if node_dist.nil?
        d = distance + (node_dist * (l + rand))
        next unless d < distances[v] and d < best # we can't relax this one
        active[v] << distances[v] = d
        parents[v] = u
        best = d if (String === end_node ? end_node == v : end_node.include?(v))
      end    
    end

    if end_node
      end_node = (end_node & parents.keys).first unless String === end_node
      return nil if not parents.include? end_node
      path = [end_node]
      while not path.last === start_node
        path << parents[path.last]
      end
      path
    else
      parents
    end
  end

  # New: breadth‑first exploration from one or many start nodes (unweighted)
  # adjacency: Hash[String => Array[String]]
  # sources: String or Array[String]
  # max_steps: Integer or nil (no limit)
  # Returns Hash[node => distance_from_any_source]
  def self.breadth_first(adjacency, sources, max_steps = nil)
    sources = [sources] unless Array === sources
    distances = {}
    queue = []

    sources.each do |s|
      next unless adjacency.include?(s)
      distances[s] = 0
      queue << s
    end

    until queue.empty?
      u = queue.shift
      d = distances[u]
      next if max_steps && d >= max_steps
      next unless adjacency.include?(u)
      adjacency[u].each do |v|
        next if distances.key?(v)
        distances[v] = d + 1
        queue << v
      end
    end

    distances
  end

  # New: enumerate nodes within k steps of a set of sources (unweighted)
  # Convenience wrapper over breadth_first
  def self.neighborhood(adjacency, sources, k)
    distances = breadth_first(adjacency, sources, k)
    distances.keys
  end
end
