# Test support: fixture loading for recorded LLM provider payloads.
#
# Not named test_*.rb on purpose: the Rakefile test pattern
# ('test/**/test_*.rb') must not collect this file.
module TestFixtures
  FIXTURES_DIR = File.expand_path('../fixtures', __dir__)

  class << self
    # TestFixtures.fixture('backends/openai_chat')
    #   -> parsed JSON from test/fixtures/backends/openai_chat.json
    def fixture(name)
      path = fixture_path(name)
      content = Open.read(path)
      JSON.parse(content)
    end

    def fixture_path(name)
      Path.setup(File.join(FIXTURES_DIR, name.to_s + '.json')).find
    end
  end
end
