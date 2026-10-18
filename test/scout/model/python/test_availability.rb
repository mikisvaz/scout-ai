require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'tmpdir'
require 'fileutils'

class TestAvailability < Test::Unit::TestCase
  def test_python_helpers_delegate_default_and_embedded_routes_to_scout_rig
    rig = ScoutRig::Testing::Availability
    calls = []
    originals = %i[python? python_modules? python_modules_reason].to_h { |name| [name, rig.method(name)] }
    rig.define_singleton_method(:python?) { |**options| calls << [:python?, options]; true }
    rig.define_singleton_method(:python_modules?) { |*modules, **options| calls << [:python_modules?, modules, options]; true }
    rig.define_singleton_method(:python_modules_reason) { |*modules, **options| calls << [:python_modules_reason, modules, options]; nil }

    assert Availability.python?(route: :embedded)
    assert Availability.python?
    assert Availability.python_modules?(:torch, route: :embedded)
    assert_nil Availability.python_modules_reason('transformers', route: :embedded)
    assert_equal [
      [:python?, {route: :embedded}],
      [:python?, {route: ScoutRig::Testing::Availability::DEFAULT_ROUTE}],
      [:python_modules?, [:torch], {route: :embedded}],
      [:python_modules_reason, ['transformers'], {route: :embedded}]
    ], calls
  ensure
    originals&.each { |name, method| rig.define_singleton_method(name, method) }
  end

  def test_huggingface_cache_checks_hf_hub_cache_and_hf_home_without_download
    Dir.mktmpdir do |dir|
      old_home, old_hub = ENV['HF_HOME'], ENV['HF_HUB_CACHE']
      ENV['HF_HOME'] = File.join(dir, 'home')
      ENV.delete('HF_HUB_CACHE')
      FileUtils.mkdir_p(File.join(ENV['HF_HOME'], 'hub', 'models--org--model', 'snapshots', 'revision'))
      assert Availability.hf_model_cached?('org/model')

      custom_hub = File.join(dir, 'custom-hub')
      ENV['HF_HUB_CACHE'] = custom_hub
      FileUtils.mkdir_p(File.join(custom_hub, 'models--other--model', 'snapshots', 'revision'))
      assert Availability.hf_model_cached?('other/model')
      assert_match(/not in local cache.*probing would download it/, Availability.hf_model_reason('missing/model'))
    ensure
      old_home.nil? ? ENV.delete('HF_HOME') : ENV['HF_HOME'] = old_home
      old_hub.nil? ? ENV.delete('HF_HUB_CACHE') : ENV['HF_HUB_CACHE'] = old_hub
    end
  end

  def test_r_package_reason_delegates_to_scout_rig
    rig = ScoutRig::Testing::Availability
    original = rig.method(:r_packages_reason)
    rig.define_singleton_method(:r_packages_reason) { |*packages, **options| [packages, options] }
    assert_equal [%w[e1071], {}], Availability.r_packages_reason('e1071')
  ensure
    rig.define_singleton_method(:r_packages_reason, original) if original
  end

  def test_endpoint_reachability_uses_tcp_primitive_not_http
    path = Object.new
    path.define_singleton_method(:exists?) { true }
    path.define_singleton_method(:yaml) { {url: 'https://example.invalid:9443/v1'} }
    original_path = Scout.method(:etc) if Scout.respond_to?(:etc)
    original_tcp = Scout::Testing::Availability.method(:tcp_reachable?)
    calls = []
    endpoint = Object.new
    endpoint.define_singleton_method(:find_with_extension) { |_extension| path }
    ai = Object.new
    ai.define_singleton_method(:[]) { |_key| endpoint }
    etc = Object.new
    etc.define_singleton_method(:AI) { ai }
    Scout.define_singleton_method(:etc) { etc }
    Scout::Testing::Availability.define_singleton_method(:tcp_reachable?) do |host, port, timeout:|
      calls << [host, port, timeout]
      true
    end

    assert Availability.endpoint_reachable?('example', 3)
    assert_equal [['example.invalid', 9443, 3]], calls
  ensure
    if original_path
      Scout.define_singleton_method(:etc, original_path)
    elsif Scout.singleton_class.instance_methods(false).include?(:etc)
      Scout.singleton_class.remove_method(:etc)
    end
    Scout::Testing::Availability.define_singleton_method(:tcp_reachable?, original_tcp) if original_tcp
  end

  def test_local_mock_endpoint_needs_no_network_probe
    assert Availability.endpoint_configured?('mock')
    assert Availability.endpoint_reachable?('mock')
    assert_nil Availability.endpoint_reason('mock')
    assert_not_include Availability.real_endpoints, 'mock'
  end

  def test_cuda_uses_embedded_python_and_generic_command_runner
    rig = ScoutRig::Testing::Availability
    generic = Scout::Testing::Availability
    old_modules, old_embedded, old_runner = rig.method(:python_modules?), rig.method(:embedded_python), generic.method(:run_command)
    calls = []
    rig.define_singleton_method(:python_modules?) { |*modules, **options| calls << [:modules, modules, options]; true }
    rig.define_singleton_method(:embedded_python) { '/test/python' }
    generic.define_singleton_method(:run_command) do |argv, timeout:|
      calls << [:run, argv, timeout]
      result = Object.new
      result.define_singleton_method(:success?) { true }
      result.define_singleton_method(:exit_status) { 0 }
      result
    end

    assert Availability.cuda?
    assert_equal [:modules, [:torch], {route: :embedded}], calls[0]
    assert_equal [:run, ['/test/python', '-c', 'import sys, torch; sys.exit(0 if torch.cuda.is_available() else 1)'], 30], calls[1]
  ensure
    rig.define_singleton_method(:python_modules?, old_modules) if old_modules
    rig.define_singleton_method(:embedded_python, old_embedded) if old_embedded
    generic.define_singleton_method(:run_command, old_runner) if old_runner
  end
end
