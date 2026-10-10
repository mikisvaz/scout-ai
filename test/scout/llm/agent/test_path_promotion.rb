require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(/test/.*), '/lib/scout/llm/agent/path.rb')

require "tmpdir"

class TestPathPromotion < Test::Unit::TestCase
  def setup
    @tmpdir = Scout.tmp.agent_path_test.find
    FileUtils.mkdir_p(@tmpdir)
    @agent = LLM.agent
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def register_text_kind(name = "text", capabilities = {})
    @agent.register_path_kind(
      name,
      "description" => "Test text paths",
      "locations" => ["project", "tmp"],
      "default_location" => "project",
      "roots" => {
        "project" => @tmpdir,
        "tmp" => File.join(@tmpdir, "tmp")
      },
      "capabilities" => capabilities
    )
  end

  def test_path_promote
    tmp_root = File.join(@tmpdir, "promote_tmp")
    project_root = File.join(@tmpdir, "promote_project")
    [tmp_root, project_root].each { |dir| FileUtils.mkdir_p(dir) }
    File.write(File.join(tmp_root, "show.slim"), "content h1 Hello\n")

    @agent.register_path_kind(
      "view",
      "locations" => ["tmp", "project"],
      "default_location" => "tmp",
      "roots" => {"tmp" => tmp_root, "project" => project_root},
      "capabilities" => {"promote" => true}
    )

    result = @agent.path_promote(
      "kind" => "view",
      "path" => "show.slim"
    )

    assert_equal true, result["promoted"]
    assert_equal "show.slim", result["path"]
    assert_equal "tmp", result["location"]
    assert_equal({"location" => "project", "path" => "show.slim"},
                 result["destination"])
    assert_equal "content h1 Hello\n", File.read(File.join(project_root, "show.slim"))
    assert !File.exist?(File.join(tmp_root, "show.slim"))
  end

  def test_path_promote_requires_capability
    register_text_kind

    assert_raise(ParameterException) do
      @agent.path_promote(
        "kind" => "text",
        "path" => "hello.txt"
      )
    end
  end

  def test_path_promote_promotes_without_a_mover_callback
    # Engine-controlled promotion: no "promote" mover callback is required or
    # consulted; the ENGINE performs the move to the authorized destination.
    definition = register_promotable_kind("promote" => nil)
    tmp_root = definition["roots"]["tmp"]
    project_root = definition["roots"]["project"]
    File.write(File.join(tmp_root, "show.slim"), "payload\n")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert_equal true, result["promoted"]
    assert_equal "payload\n", File.read(File.join(project_root, "show.slim"))
    assert !File.exist?(File.join(tmp_root, "show.slim"))
  end

  def test_path_promote_legacy_mover_callback_is_not_invoked
    # A legacy "promote" mover callback must NOT be invoked by the engine;
    # the engine is the only writer.  Any callback content must be absent.
    called = false
    definition = register_promotable_kind(
      "promote" => lambda do |_agent, _path, _location, _args|
        called = true
        {"promoted" => true}
      end
    )
    tmp_root = definition["roots"]["tmp"]
    File.write(File.join(tmp_root, "show.slim"), "payload\n")

    @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert !called
    assert_equal "payload\n",
                 File.read(File.join(definition["roots"]["project"], "show.slim"))
  end

  def test_path_promote_callback_redirect_attack_writes_only_at_authorized_destination
    # REDIRECT ATTACK: a kind whose legacy mover callback tries to write
    # somewhere else.  Content must land ONLY at the engine-authorized
    # destination; the redirect target must not be created.
    outside = Dir.mktmpdir("path-outside")
    redirect_target = File.join(outside, "hijacked.txt")
    definition = register_promotable_kind(
      "promote" => lambda do |_agent, _path, _location, args|
        File.write(redirect_target, "hijacked")
        FileUtils.rm(args["promotion_source_target"])
        {"promoted" => true, "destination" => redirect_target}
      end
    )
    tmp_root = definition["roots"]["tmp"]
    project_root = definition["roots"]["project"]
    source = File.join(tmp_root, "show.slim")
    File.write(source, "legitimate\n")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    authorized = File.join(project_root, "show.slim")
    assert_equal true, result["promoted"]
    # The engine's authorized endpoint wins over any callback claim.
    assert_equal authorized, result["promotion_target"]
    assert_equal({"location" => "project", "path" => "show.slim"},
                 result["destination"])
    assert_equal "legitimate\n", File.read(authorized)
    assert !File.exist?(redirect_target)
    assert !File.exist?(source)
    # Nothing else was mutated: only the two authorized endpoints changed.
    assert_equal ["show.slim"], Dir.children(project_root).sort
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  def test_path_promote_post_move_hook_receives_authorized_endpoints
    hook_calls = []
    definition = register_promotable_kind(
      "promotion_post_move" => lambda do |agent, path, location, args|
        hook_calls << [agent, path, location, args]
        {"extra" => "cleanup-done"}
      end
    )
    tmp_root = definition["roots"]["tmp"]
    File.write(File.join(tmp_root, "show.slim"), "payload\n")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert_equal 1, hook_calls.length
    agent, path, location, args = hook_calls.first
    assert_equal @agent, agent
    assert_equal "show.slim", path
    assert_equal "tmp", location
    assert_equal File.join(definition["roots"]["project"], "show.slim"),
                 args["promotion_target"]
    assert_equal File.join(tmp_root, "show.slim"),
                 args["promotion_source_target"]
    assert_equal({"location" => "project", "path" => "show.slim"},
                 args["promotion_destination"])
    assert_equal false, args["overwrite"]
    # Hook extras merge into the result without overriding engine fields.
    assert_equal "cleanup-done", result["extra"]
    assert_equal true, result["promoted"]
  end

  def register_promotable_kind(overrides = {})
    tmp_root = File.join(@tmpdir, "ptmp")
    project_root = File.join(@tmpdir, "pproject")
    outside_root = File.join(@tmpdir, "poutside")
    [tmp_root, project_root, outside_root].each { |dir| FileUtils.mkdir_p(dir) }

    definition = {
      "locations" => %w[tmp project],
      "default_location" => "tmp",
      "roots" => {"tmp" => tmp_root, "project" => project_root},
      "capabilities" => {"promote" => true},
      "promotion_destination" => {"location" => "project"}
    }.merge(overrides)

    @agent.register_path_kind("view", definition)
    definition
  end

  def test_promotion_moves_content_to_project_location
    definition = register_promotable_kind
    tmp_root = definition["roots"]["tmp"]
    project_root = definition["roots"]["project"]
    File.write(File.join(tmp_root, "show.slim"), "content h1 Hello\n")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert_equal true, result["promoted"]
    assert_equal File.join(project_root, "show.slim"), result["promotion_target"]
    assert_equal({"location" => "project", "path" => "show.slim"},
                 result["destination"])
    assert_equal "content h1 Hello\n", File.read(File.join(project_root, "show.slim"))
    assert !File.exist?(File.join(tmp_root, "show.slim"))
  end

  def test_promotion_denies_source_outside_roots
    definition = register_promotable_kind
    outside = File.join(@tmpdir, "poutside", "rogue.txt")
    File.write(outside, "rogue")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => outside)
    end
    assert_match(/Path access denied by sandbox/, error.message)

    assert_equal "rogue", File.read(outside)
    assert !File.exist?(File.join(definition["roots"]["project"], "rogue.txt"))
  end

  def test_promotion_denies_destination_location_without_configured_root
    definition = register_promotable_kind(
      "locations" => %w[tmp elsewhere],
      "promotion_destination" => {"location" => "elsewhere"}
    )
    File.write(File.join(definition["roots"]["tmp"], "show.slim"), "content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/No root configured for view at location elsewhere/, error.message)

    assert File.exist?(File.join(definition["roots"]["tmp"], "show.slim"))
    assert !File.exist?(File.join(@tmpdir, "elsewhere", "show.slim"))
  end

  def test_promotion_denies_destination_traversal
    definition = register_promotable_kind(
      "promotion_destination" => {"location" => "project", "path" => "../escape.txt"}
    )
    source = File.join(definition["roots"]["tmp"], "show.slim")
    File.write(source, "content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Path access denied by sandbox/, error.message)

    assert File.exist?(source)
    assert !File.exist?(File.join(@tmpdir, "escape.txt"))
  end

  def test_promotion_denies_absolute_destination_outside_roots
    definition = register_promotable_kind(
      "promotion_destination" => {
        "location" => "project",
        "path" => File.join(@tmpdir, "poutside", "absolute.txt")
      }
    )
    source = File.join(definition["roots"]["tmp"], "show.slim")
    File.write(source, "content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Path access denied by sandbox/, error.message)

    assert File.exist?(source)
    assert !File.exist?(File.join(@tmpdir, "poutside", "absolute.txt"))
  end

  def test_promotion_denies_symlinked_destination_escape
    definition = register_promotable_kind(
      "promotion_destination" => {"location" => "project", "path" => "link.slim"}
    )
    source = File.join(definition["roots"]["tmp"], "show.slim")
    File.write(source, "content")
    escape_target = File.join(@tmpdir, "poutside", "escape_target.txt")
    File.symlink(escape_target, File.join(definition["roots"]["project"], "link.slim"))

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Path access denied by sandbox/, error.message)

    assert File.exist?(source)
    assert !File.exist?(escape_target)
  end

  def test_promotion_denies_existing_destination_by_default
    definition = register_promotable_kind
    source = File.join(definition["roots"]["tmp"], "show.slim")
    File.write(source, "new content")
    destination = File.join(definition["roots"]["project"], "show.slim")
    File.write(destination, "old content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Promotion destination already exists/, error.message)

    assert_equal "old content", File.read(destination)
    assert_equal "new content", File.read(source)
  end

  def test_promotion_overwrite_replaces_existing_destination
    definition = register_promotable_kind
    source = File.join(definition["roots"]["tmp"], "show.slim")
    File.write(source, "new content")
    destination = File.join(definition["roots"]["project"], "show.slim")
    File.write(destination, "old content")

    result = @agent.path_promote(
      "kind" => "view", "path" => "show.slim", "overwrite" => true
    )

    assert_equal true, result["promoted"]
    assert_equal "new content", File.read(destination)
    assert !File.exist?(source)
  end

  def test_promotion_rejects_invalid_destination_specification
    definition = register_promotable_kind("promotion_destination" => 42)
    File.write(File.join(definition["roots"]["tmp"], "show.slim"), "content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Invalid promotion destination for path kind view/, error.message)

    assert File.exist?(File.join(definition["roots"]["tmp"], "show.slim"))
    assert !File.exist?(File.join(definition["roots"]["project"], "show.slim"))
  end

  def test_promotion_callable_destination_spec_is_rejected
    # A Callable promotion destination would have to run BEFORE the
    # destination is authorized; a side-effecting callable could mutate
    # anywhere.  The declarative-only contract rejects it up front.
    called = false
    definition = register_promotable_kind(
      "promotion_destination" => lambda do |_agent, _path, _location, _args|
        called = true
        {"location" => "project"}
      end
    )
    File.write(File.join(definition["roots"]["tmp"], "show.slim"), "content")

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "show.slim")
    end
    assert_match(/Invalid promotion destination for path kind view/, error.message)
    assert !called

    assert File.exist?(File.join(definition["roots"]["tmp"], "show.slim"))
    assert !File.exist?(File.join(definition["roots"]["project"], "show.slim"))
  end

  def test_promotion_string_destination_spec_selects_location
    definition = register_promotable_kind("promotion_destination" => "project")
    File.write(File.join(definition["roots"]["tmp"], "show.slim"), "content")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert_equal({"location" => "project", "path" => "show.slim"},
                 result["destination"])
    assert File.exist?(File.join(definition["roots"]["project"], "show.slim"))
    assert !File.exist?(File.join(definition["roots"]["tmp"], "show.slim"))
  end

  def test_promotion_destination_path_renames_target
    definition = register_promotable_kind(
      "promotion_destination" => {"location" => "project", "path" => "release.slim"}
    )
    File.write(File.join(definition["roots"]["tmp"], "show.slim"), "content")

    result = @agent.path_promote("kind" => "view", "path" => "show.slim")

    assert_equal File.join(definition["roots"]["project"], "release.slim"),
                 result["promotion_target"]
    assert File.exist?(File.join(definition["roots"]["project"], "release.slim"))
    assert !File.exist?(File.join(definition["roots"]["tmp"], "show.slim"))
  end

  def test_promotion_missing_source_is_rejected_before_anything_moves
    definition = register_promotable_kind

    error = assert_raise(ParameterException) do
      @agent.path_promote("kind" => "view", "path" => "ghost.slim")
    end
    assert_match(/Path does not exist or is not readable/, error.message)

    assert !File.exist?(File.join(definition["roots"]["project"], "ghost.slim"))
  end

  # ------------------------------------------------------------------
  # Selector semantics regression matrix (lines + chars)
  #
  # Lines contract: 0-based start, exclusive end; a line includes its
  # terminator; untouched lines byte-identical; final newline preserved IFF
  # it existed before the edit; empty replacement deletes the span.
  # ------------------------------------------------------------------


end
