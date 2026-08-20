require 'test/unit'
$LOAD_PATH.unshift(File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib')))
$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__)))
require 'scout'
require 'scout-ai'

# Offline test endpoints/fixtures support. Files under test/support are
# deliberately NOT named test_*.rb so the Rakefile pattern
# ('test/**/test_*.rb') does not collect them as tests.
require File.join(File.dirname(__FILE__), 'support', 'fixtures')
require File.join(File.dirname(__FILE__), 'support', 'mock_backend')
require File.join(File.dirname(__FILE__), 'support', 'fake_clients')
require File.join(File.dirname(__FILE__), 'support', 'availability')

# ScoutCoder: Scout.etc.AI['test'] resolves through the Scout path maps, and
# the first map in Scout.map_order wins. Scout.prepend_path(:name, map) adds
# the map AND unshifts it into map_order, which is what makes the repo-local
# test/etc tree take precedence over ~/.scout/etc. Note the map must include
# the literal '{TOPLEVEL}/{SUBPATH}' suffix and, because the path is 'etc/AI'
# (TOPLEVEL 'etc', SUBPATH 'AI'), the map root must be the test directory so
# it expands to <repo>/test/etc/AI/... .
Scout.prepend_path :test_etc, File.join(File.expand_path(File.dirname(__FILE__)), '{TOPLEVEL}/{SUBPATH}')

# Default offline LLM configuration: ask/embed go through endpoint 'test'
# (test/etc/AI/test.yaml -> backend: mock, model: mock-model) unless a test
# overrides it explicitly.
Scout::Config.set({endpoint: 'test'}, :llm)
Scout::Config.set({endpoint: 'test'}, :embed, :llm)
Scout::Config.set({backend: :mock}, :embed, :llm)

class Test::Unit::TestCase

  def assert_equal_path(path1, path2)
    assert_equal File.expand_path(path1), File.expand_path(path2)
  end

  def self.tmpdir
    @@tmpdir ||= Path.setup('tmp/test_tmpdir').find
  end

  def tmpdir
    @tmpdir ||= Test::Unit::TestCase.tmpdir
  end

  setup do
    Open.rm_rf tmpdir
    TmpFile.tmpdir = tmpdir.tmpfiles
    Log::ProgressBar.default_severity = 0
    Persist.cache_dir = tmpdir.var.cache
    Persist::MEMORY_CACHE.clear
    Open.remote_cache_dir = tmpdir.var.cache
    Workflow.directory = tmpdir.var.jobs
    Workflow.workflows.each{|wf| wf.directory = Workflow.directory[wf.name] }
    Entity.entity_property_cache = tmpdir.entity_properties if defined?(Entity)
    LLM::Mock.reset! if defined?(LLM::Mock)
  end
  
  teardown do
    Open.rm_rf tmpdir
  end

  def self.datadir_test
    Path.setup(File.join(File.dirname(__FILE__), 'data'))
  end

  def self.datafile_test(file)
    datadir_test[file.to_s]
  end

  def datadir_test
    Test::Unit::TestCase.datadir_test
  end

  def datafile_test(file)
    Test::Unit::TestCase.datafile_test(file)
  end

  def agent(name = nil, options = {})
    require 'scout/llm/agent'
    options[:endpoint] = Scout::Config.get(:endpoint, :test)
    if name.nil?
      LLM::Agent.new(**options)
    else
      LLM.load_agent name, options
    end
  end
end

module Object::Person
  extend Entity

  annotation :language

  property :salutation do
    case language
    when 'es'
      "Hola #{self}"
    else
      "Hi #{self}"
    end
  end
end

Object::Person.add_identifiers Test::Unit::TestCase.datafile_test(:person).identifiers
