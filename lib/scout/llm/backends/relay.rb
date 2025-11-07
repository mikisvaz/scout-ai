require 'scout'
require_relative '../chat'

module LLM
	module Relay
    def self.upload(server, file)
      id = Misc.digest(Open.read(file))
      CMD.cmd("scp #{file} #{server}:.scout/var/ask/#{ id }.json")
      id
    end

    def self.gather(server, id)
      TmpFile.with_file do |file|
        begin
          CMD.cmd("scp #{server}:.scout/var/ask/reply/#{ id }.json #{ file }")
          JSON.parse(Open.read(file))
        rescue
          sleep 1
          retry
        end
      end
    end

    def self.ask(question, options = {}, &block)
      server = IndiferentHash.process_options options, :server
      server ||= Scout::Config.get :server, :ask_relay, :relay, :ask, env: 'ASK_ENDPOINT,LLM_ENDPOINT', default: :openai

      options[:question] = question
      TmpFile.with_file(options.to_json) do |file|
        id = upload(server, file)
        gather(server, id)
      end
    end
  end
end
