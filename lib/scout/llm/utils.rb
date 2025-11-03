module LLM
  def self.get_url_server_tokens(url, prefix=nil)
    return get_url_server_tokens(url).collect{|e| prefix.to_s + "." + e } if prefix

    server = url.match(/(?:https?:\/\/)?([^\/:]*)/)[1] || "NOSERVER"
    parts = server.split(".")
    parts.pop if parts.last.length <= 3
    combinations = []
    (1..parts.length).each do |l|
      parts.each_cons(l){|p| combinations << p*"."}
    end
    (parts + combinations + [server]).uniq
  end

  def self.get_url_config(key, url = nil, *tokens)
    hash = tokens.pop if Hash === tokens.last 
    if url
      url_tokens = tokens.inject([]){|acc,prefix| acc.concat(get_url_server_tokens(url, prefix))}
      all_tokens = url_tokens + tokens
    else
      all_tokens = tokens
    end
    Scout::Config.get(key, *all_tokens, hash)
  end


end
