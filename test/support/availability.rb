# Test support: runtime and domain-specific availability probes.
#
# Not named test_*.rb on purpose: the Rakefile test pattern
# ('test/**/test_*.rb') must not collect this file.
#
# Python and R runtime probes are opt-in Scout-Rig test helpers. CUDA and
# Hugging Face cache checks remain Scout-AI-specific; endpoint configuration
# remains local and endpoint reachability is a TCP-only check. None of these
# checks performs HTTP/inference or downloads a model.
require 'scout-rig/testing/availability'
require 'uri'

module Availability
  class << self
    def python?(route: ScoutRig::Testing::Availability::DEFAULT_ROUTE)
      ScoutRig::Testing::Availability.python?(route: route)
    end

    def python_modules?(*modules, route: ScoutRig::Testing::Availability::DEFAULT_ROUTE)
      ScoutRig::Testing::Availability.python_modules?(*modules, route: route)
    end

    def python_modules_reason(*modules, route: ScoutRig::Testing::Availability::DEFAULT_ROUTE)
      ScoutRig::Testing::Availability.python_modules_reason(*modules, route: route)
    end

    # torch is importable (does NOT imply CUDA)
    def torch?(route: :embedded)
      python_modules?(:torch, route: route)
    end

    # torch is importable AND reports a usable CUDA device. The subprocess
    # uses Scout-Rig's embedded-interpreter selection and Scout-Essentials'
    # bounded argv executor; this is only an omission probe, never a rescue
    # around the model's real PyCall operations.
    def cuda?
      return false unless torch?(route: :embedded)

      executable = ScoutRig::Testing::Availability.embedded_python
      return false unless executable

      result = Scout::Testing::Availability.run_command(
        [executable, '-c', 'import sys, torch; sys.exit(0 if torch.cuda.is_available() else 1)'],
        timeout: 30
      )
      result.success? && result.exit_status == 0
    end

    # A Hugging Face model is already in the local cache; this NEVER triggers
    # a download. HF_HUB_CACHE overrides HF_HOME/hub, matching the cache
    # layout used by huggingface_hub.
    def hf_model_cached?(repo)
      hub = ENV['HF_HUB_CACHE']
      hub ||= File.join(ENV['HF_HOME'] || File.join(Dir.home, '.cache', 'huggingface'), 'hub')
      repo_dir = 'models--' + repo.to_s.gsub('/', '--')
      path = File.join(hub, repo_dir)
      Dir.exist?(path) && Dir.glob(File.join(path, 'snapshots', '*')).any?
    end

    def hf_model_reason(repo)
      return nil if hf_model_cached?(repo)

      cache = ENV['HF_HUB_CACHE'] || ENV['HF_HOME'] || '~/.cache/huggingface'
      "huggingface model #{repo} not in local cache (cache root=#{cache}); probing would download it"
    end

    # Scout-Rig offers reference Rscript/package probes; these do not imply
    # an R runtime in Scout-AI. Keep these adapters because the integration
    # model tests use them to omit when e1071 is unavailable.
    def rscript?
      ScoutRig::Testing::Availability.rscript?
    end

    def r_packages?(*packages)
      ScoutRig::Testing::Availability.r_packages?(*packages)
    end

    def r_packages_reason(*packages)
      ScoutRig::Testing::Availability.r_packages_reason(*packages)
    end

    # An endpoint yaml exists in Scout's configuration paths. This is a
    # local filesystem check; it never contacts the endpoint.
    def endpoint_configured?(endpoint)
      Scout.etc.AI[endpoint.to_s].find_with_extension(:yaml).exists?
    end

    # The endpoint's URL accepts a TCP connection within timeout. This only
    # establishes TCP reachability, not HTTP, authentication or inference.
    # Endpoints without URLs (mock, relay through scp, ...) count as
    # reachable once configured.
    def endpoint_reachable?(endpoint, timeout = 5)
      path = Scout.etc.AI[endpoint.to_s].find_with_extension(:yaml)
      return false unless path.exists?

      url = path.yaml[:url] || path.yaml['url']
      return true if url.nil?

      uri = URI.parse(url.to_s)
      port = uri.port || (uri.scheme == 'https' ? 443 : 80)
      Scout::Testing::Availability.tcp_reachable?(uri.host, port, timeout: timeout)
    rescue URI::InvalidURIError
      false
    end

    # Combined: configured AND (no url OR reachable)
    def endpoint_available?(endpoint)
      endpoint_configured?(endpoint) && endpoint_reachable?(endpoint)
    end

    def endpoint_reason(endpoint)
      return "endpoint #{endpoint} not configured (no yaml in the Scout AI paths)" unless endpoint_configured?(endpoint)
      return "endpoint #{endpoint} configured but not reachable" unless endpoint_reachable?(endpoint)

      nil
    end

    # All endpoint names defined in Scout.etc.AI across the search paths.
    def configured_endpoints
      Scout.etc.AI.glob('*.yaml').collect { |file| File.basename(file, '.yaml') }.uniq
    end

    # Endpoints that are real inference services (anything but the offline
    # mock one defined by this test suite).
    def real_endpoints
      configured_endpoints.reject { |endpoint| endpoint == 'mock' }
    end
  end
end
