module LLM
  def self.parse(question, role = nil)
    role = :user if role.nil?

    if Array === question
      question.collect do |q|
        Hash === q ? q : {role: role, content: q}
      end
    else
      question.split("\n").collect do |line|
        if line.include?("\t")
          question_role, _sep, q = line.partition("\t")
        elsif m = line.match(/([^\s]*): ?(.*)/)
          question_role, q = m.values_at 1, 2
        else
          question_role = role
          q = line
        end
        {role: question_role, content: q}
      end
    end
  end
end
