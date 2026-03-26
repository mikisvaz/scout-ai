module Chat
  def self.serialize_meta(meta) 
    keys = meta.keys

    keys = keys.sort_by do |k|
      v = meta[k]
      String === v ? v.length : 0
    end

    keys.collect{|k| [k,meta[k]] * "="} * " "  
  end  

  def self.parse_meta(str) 
    parts = str.split('=')    
    meta = {}   
    key = parts.shift 
    while next_part = parts.shift

      if parts.any?
        rnext_part = next_part.reverse
        rkey,_, rvalue = rnext_part.partition(/\s+/)
        next_key = rkey.reverse
        value = rvalue.reverse
      else
        value = next_part
      end

      case value      
      when /^-?\d+$/
        meta[key] = value.to_i 
      when /^-?\d+\.\d+$/ 
        meta[key] = value.to_f      
      else       
        meta[key] = value
      end

      key = next_key
    end 

    meta
  end  

  def self.meta(messages)  
    meta_msg = pull(messages, :meta)
    return nil if meta_msg.nil?
    parse_meta meta_msg[:content] 
  end
end
