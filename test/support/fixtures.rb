# Test support: fixture loading for recorded LLM provider payloads.
#
# Not named test_*.rb on purpose: the Rakefile test pattern
# ('test/**/test_*.rb') must not collect this file.
#
# Deliberately free of the production IO abstractions (Path/Open):
# resolution is plain File math rooted at test/fixtures, every reference is
# validated before it touches the filesystem, and failures raise
# FixtureError with a message naming the reference and/or the resolved
# path. Fake-client factories live in TestClients (support/fake_clients.rb);
# this module owns only the static recorded payloads.
#
# ScoutCoder: Scout::Testing.fixture_root/fixture_path (scout-essentials)
# were evaluated for the root resolution; they are plain joiners with no
# traversal rejection, absolute-path rejection or error handling, so the
# loader is implemented here and the root stays a plain __dir__-relative
# constant (see tmp/notes/fixture-workstream.md).
module TestFixtures
  FIXTURES_DIR = File.expand_path('../fixtures', __dir__)

  # Raised for invalid fixture references (empty, absolute, `..`
  # traversal, symlink escapes), missing files and invalid JSON. Messages
  # always name the offending reference and/or the resolved path.
  class FixtureError < StandardError; end

  class << self
    # TestFixtures.fixture('backends/openai_chat')
    #   -> parsed JSON from test/fixtures/backends/openai_chat.json
    #
    # `root:` is injectable so the loader tests can exercise the
    # resolution rules against a temporary tree without touching the
    # recorded payloads.
    def fixture(name, root: FIXTURES_DIR)
      path = fixture_path(name, root: root)

      unless File.file?(path)
        raise FixtureError, "test fixture not found: #{name.inspect} (expected at #{path})"
      end

      begin
        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        raise FixtureError, "invalid JSON in test fixture #{path}: #{e.message}"
      end
    end

    # Absolute path of the named fixture ('.json' appended), e.g.
    # TestFixtures.fixture_path('backends/openai_chat').
    #
    # Rejects, before any filesystem access, every reference that is not a
    # plain relative path inside `root`: empty/NUL-bearing strings,
    # absolute paths, and any `..` segment. After resolution an existing
    # target must also sit really (realpath, so symlinks are followed)
    # inside `root`. Does NOT require the file to exist, mirroring the old
    # Path#find semantics; existence is checked by .fixture.
    def fixture_path(name, root: FIXTURES_DIR)
      ref = name.to_s

      if ref.empty? || ref.include?("\0")
        raise FixtureError, "invalid fixture reference: #{ref.inspect} (root: #{root})"
      end

      if ref.start_with?(File::SEPARATOR) || ref.match?(%r{\A[A-Za-z]:[\\/]})
        raise FixtureError, "absolute fixture reference rejected: #{ref.inspect} (root: #{root})"
      end

      if ref.split(File::SEPARATOR).include?('..')
        raise FixtureError, "fixture reference escapes the fixtures root: #{ref.inspect} (root: #{root})"
      end

      root = File.expand_path(root)
      path = File.expand_path(File.join(root, ref + '.json'))

      unless path == root || path.start_with?(root + File::SEPARATOR)
        raise FixtureError, "fixture reference escapes the fixtures root: #{ref.inspect} (resolved to #{path})"
      end

      if File.exist?(path)
        real_root = File.realpath(root)
        real = File.realpath(path)
        unless real == real_root || real.start_with?(real_root + File::SEPARATOR)
          raise FixtureError,
                "fixture path escapes the fixtures root through a symlink: #{ref.inspect} (resolved to #{real})"
        end
      end

      path
    end
  end
end
