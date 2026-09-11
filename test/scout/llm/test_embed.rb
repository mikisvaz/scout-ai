require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

require 'scout/llm/embed'

class TestLLMEmbed < Test::Unit::TestCase
  def test_embed_deterministic_fixed_dimension
    # ScoutCoder: the default embed backend for tests is the registered
    # LLM::Mock backend (Scout::Config.set({backend: :mock}, :embed, :llm) in
    # test_helper), so LLM.embed resolves through the LLM::BACKENDS registry
    # fallback and never touches the network.
    v1 = LLM.embed('a text', endpoint: :mock)
    v2 = LLM.embed('a text', endpoint: :mock)

    assert_instance_of Array, v1
    assert_equal LLM::Mock::DIMENSIONS, v1.length
    assert v1.all? { |e| Float === e }
    assert_equal v1, v2
  end

  def test_embed_array_input
    vectors = LLM.embed(['one two', 'two three'], endpoint: :mock)

    assert_equal 2, vectors.length
    assert_equal [LLM::Mock::DIMENSIONS, LLM::Mock::DIMENSIONS], vectors.collect(&:length)
    assert_equal LLM.embed('one two', endpoint: :mock), vectors.first
  end

  def test_embed_shared_words_closer
    # cosine similarity: texts sharing words must be closer than disjoint texts
    def cos(a, b)
      dot = a.zip(b).inject(0.0) { |acc, (x, y)| acc + x * y }
      na  = Math.sqrt(a.inject(0.0) { |acc, x| acc + x * x })
      nb  = Math.sqrt(b.inject(0.0) { |acc, x| acc + x * x })
      dot / (na * nb)
    end

    shared  = LLM.embed('crime and theft', endpoint: :mock)
    similar = LLM.embed('crime theft violence', endpoint: :mock)
    other   = LLM.embed('puppies and flowers', endpoint: :mock)

    assert cos(shared, similar) > cos(shared, other)
  end

  # ScoutCoder: hermetic against request-level env. EMBED_ENDPOINT /
  # LLM_ENDPOINT act as an EXPLICIT endpoint request (same precedence as the
  # options hash), so a value leaked into the test process would make even a
  # backend-pinned call raise "Endpoint not found". Neutralize both for the
  # duration of the assertion; the repo-level config pin (backend: :mock)
  # then governs dispatch. The raise-on-requested-but-absent behavior itself
  # is covered in test_embed_missing_endpoint_raises.
  def test_embed_explicit_backend
    saved_embed_endpoint, saved_llm_endpoint = ENV['EMBED_ENDPOINT'], ENV['LLM_ENDPOINT']
    ENV.delete 'EMBED_ENDPOINT'
    ENV.delete 'LLM_ENDPOINT'
    begin
      assert_equal LLM::Mock.embed('a text', endpoint: :mock), LLM.embed('a text', backend: :mock)
    ensure
      ENV['EMBED_ENDPOINT'] = saved_embed_endpoint if saved_embed_endpoint
      ENV['LLM_ENDPOINT'] = saved_llm_endpoint if saved_llm_endpoint
    end
  end

  # ScoutCoder: bug M4 regression. The endpoint yaml lookup used the
  # extensionless `Scout.etc.AI[endpoint].exists?`, so a standard
  # `etc/AI/<endpoint>.yaml` was never merged (asymmetric with ask/image,
  # which use find_with_extension(:yaml)), and a missing endpoint fell
  # through to the config defaults silently. Both probed offline here with
  # a throwaway endpoint yaml and a recording backend in the registry.
  def test_embed_endpoint_yaml_is_merged
    base = tmpdir
    etc_ai = Path.setup(base)['etc/AI']
    Open.mkdir(etc_ai)
    Open.write(etc_ai['m4_endpoint.yaml'], {'backend' => 'm4_rec', 'model' => 'm4-model'}.to_yaml)

    Scout.prepend_path :m4_test_etc, File.join(base, '{TOPLEVEL}/{SUBPATH}')
    received = nil
    LLM::BACKENDS[:m4_rec] = Module.new do
      define_singleton_method(:embed) do |_text, options|
        $m4_received = IndiferentHash.setup(options.dup)
        [0.0] * LLM::Mock::DIMENSIONS
      end
    end

    # sanity: the yaml exists for the with-extension lookup and NOT for the
    # extensionless one that used to gate the merge
    assert Scout.etc.AI[:m4_endpoint].find_with_extension(:yaml).exists?
    assert !Scout.etc.AI[:m4_endpoint].exists?

    LLM.embed('a text', endpoint: :m4_endpoint)
    assert_equal 'm4-model', $m4_received['model']

    # an endpoint yaml naming a backend drives dispatch through the registry
    LLM::BACKENDS.delete(:m4_rec)
    Open.write(etc_ai['m4_endpoint.yaml'], {'backend' => 'mock'}.to_yaml)
    assert_equal LLM::Mock::DIMENSIONS, LLM.embed('a text', endpoint: :m4_endpoint).length
  ensure
    LLM::BACKENDS.delete(:m4_rec)
    Scout.path_maps.delete(:m4_test_etc) if Scout.path_maps.include?(:m4_test_etc)
    Scout.map_order.delete(:m4_test_etc) if Scout.map_order.include?(:m4_test_etc)
    $m4_received = nil
  end

  def test_embed_missing_endpoint_raises
    # ask/image raise "Endpoint not found <name>" for a requested-but-absent
    # endpoint; embed used to fall through to the config defaults silently.
    # The synthesized `:embed` fallback name is NOT a request, so a call
    # without any endpoint still works (backend-configured path).
    error = assert_raise(RuntimeError) { LLM.embed('a text', endpoint: :m4_no_such_endpoint) }
    assert_include error.message, 'Endpoint not found'

    # ScoutCoder: hermetic. With no explicit endpoint the synthesized `:embed`
    # name is still resolved as etc/AI/embed.yaml, and a user-level file there
    # (~/.scout/etc/AI/embed.yaml, e.g. `backend: ollama`) legitimately
    # contributes defaults AHEAD of the config-pinned backend, exactly like
    # LLM.ask for its endpoint yaml. On an account with such a file (and
    # OLLAMA_URL/OLLAMA_KEY exported) the bare call dispatches to that backend
    # and returns its dimensionality (observed: 1024 for mxbai-embed-large),
    # so this no-endpoint assertion pins the backend explicitly instead of
    # relying on the absence of user configuration. The endpoint resolution
    # path is still exercised: the synthesized `:embed` name is looked up as a
    # yaml and must not raise, while a genuinely requested endpoint does.
    #
    # EMBED_ENDPOINT/LLM_ENDPOINT are REQUEST-level environment, i.e. an
    # explicit endpoint request for every embed call; a leaked value would
    # make even these calls raise "Endpoint not found". Neutralize it inside
    # the test (ENV.delete inside an ensure-protected block) so the
    # environment-dependent assertions below are hermetic while the repo-level
    # config pin (backend: :mock in test_helper) still governs resolution.
    saved_embed_endpoint, saved_llm_endpoint = ENV['EMBED_ENDPOINT'], ENV['LLM_ENDPOINT']
    ENV.delete 'EMBED_ENDPOINT'
    ENV.delete 'LLM_ENDPOINT'
    begin
      assert_equal LLM::Mock::DIMENSIONS, LLM.embed('a text', backend: :mock).length
      # The bare call exercises the synthesized-fallback path itself: no raise,
      # and it uses the offline backend UNLESS the environment legitimately
      # configures an etc/AI/embed.yaml (a user-level file resolves through the
      # same path maps ask/image use). Keep the assertion hermetic: assert the
      # offline dimensionality only when no such endpoint yaml is resolvable,
      # otherwise the dimensionality belongs to the configured backend and the
      # pinned call above already proves the fallback does not raise.
      unless Scout.etc.AI[:embed].find_with_extension(:yaml).exists?
        assert_equal LLM::Mock::DIMENSIONS, LLM.embed('a text').length
      end
    ensure
      ENV['EMBED_ENDPOINT'] = saved_embed_endpoint if saved_embed_endpoint
      ENV['LLM_ENDPOINT'] = saved_llm_endpoint if saved_llm_endpoint
    end
  end
end
