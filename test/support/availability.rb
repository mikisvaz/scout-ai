# Test support: bounded availability probes for conditional test omissions.
#
# Not named test_*.rb on purpose: the Rakefile test pattern
# ('test/**/test_*.rb') must not collect this file.
#
# Every probe returns true/false (never raises, never downloads, never hangs).
# Intended usage in a test:
#
#   omit 'torch CUDA unavailable' unless Availability.cuda?
#
# Guidelines honoured here:
#   * Huggingface model presence is checked against the local HF cache only
#     (HF_HOME/hub or ~/.cache/huggingface/hub), NEVER through the
#     transformers API: importing transformers or building a tokenizer would
#     start a multi-GB download for anything that is not already cached.
#   * Python module probes run `python -c "import ..."` in a fresh process
#     with a hard timeout, so a hanging import cannot block the suite.
#   * Results are memoized per process: probes are cheap but not free.
module Availability
  DEFAULT_TIMEOUT = 60

  class << self
    def memo(name)
      cache = (@cache ||= {})
      return cache[name] if cache.key?(name)
      cache[name] = begin
        yield
      rescue Exception
        false
      end
    end

    def python_executable
      ENV['SCOUT_TEST_PYTHON'] || 'python'
    end

    # python itself is usable (python executable present and runnable)
    def python?
      memo(:python) do
        run_bounded([python_executable, '-c', 'import sys; sys.exit(0)'], 30)
        true
      end
    end

    # all listed python modules import cleanly (fresh process, bounded)
    def python_modules?(*mods)
      memo(:"python_modules_#{mods.join(',')}") do
        raise Errno::ENOENT unless python?
        code = mods.collect { |m| "import #{m}" } * ';'
        _out, _err, status = run_bounded([python_executable, '-c', code], DEFAULT_TIMEOUT, capture: true)
        status == 0
      end
    end

    # informative reason string when a python module is missing, nil otherwise
    def python_modules_reason(*mods)
      return 'python unavailable' unless python?
      code = mods.collect { |m| "import #{m}" } * ';'
      out, _err, status = run_bounded([python_executable, '-c', code], DEFAULT_TIMEOUT, capture: true)
      return nil if status == 0
      "python modules missing (#{mods * ','}): #{out.split("\n").last.to_s.strip}"
    end

    # torch is importable (does NOT imply CUDA)
    def torch?
      python_modules?('torch')
    end

    # torch is importable AND reports a usable CUDA device
    def cuda?
      memo(:cuda) do
        return false unless torch?
        code = 'import sys, torch; sys.exit(0 if torch.cuda.is_available() else 1)'
        _out, _err, status = run_bounded([python_executable, '-c', code], DEFAULT_TIMEOUT, capture: true)
        status == 0
      end
    end

    # A Huggingface model is already in the local cache; this NEVER triggers a
    # download (see the note at the top of the file).
    def hf_model_cached?(repo)
      memo(:"hf_model_#{repo}") do
        hub = ENV['HF_HOME'] ? File.join(ENV['HF_HOME'], 'hub') : File.join(Dir.home, '.cache', 'huggingface', 'hub')
        repo_dir = 'models--' + repo.to_s.tr('/', '--')
        path = File.join(hub, repo_dir)
        Dir.exist?(path) && Dir.glob(File.join(path, 'snapshots', '*')).any?
      end
    end

    # Reason for a missing huggingface model
    def hf_model_reason(repo)
      return "huggingface model #{repo} not in local cache (HF_HOME=#{ENV['HF_HOME'] || '~/.cache/huggingface'}); probing would download it" unless hf_model_cached?(repo)
      nil
    end

    # Rscript is present
    def rscript?
      memo(:rscript) { which?('Rscript') }
    end

    # R is present and the listed packages are installed (bounded Rscript -e)
    def r_packages?(*pkgs)
      memo(:"r_packages_#{pkgs.join(',')}") do
        return false unless rscript?
        code = "cat(if (all(c(#{pkgs.collect { |p| "'#{p}'" } * ', '}) %in% rownames(installed.packages()))) 'yes' else 'no')"
        out, _err, status = run_bounded(['Rscript', '-e', code], DEFAULT_TIMEOUT, capture: true)
        status == 0 && out.strip == 'yes'
      end
    end

    def r_packages_reason(*pkgs)
      return 'Rscript not found' unless rscript?
      return nil if r_packages?(*pkgs)
      "R packages missing: #{pkgs * ','}"
    end

    #{{{ endpoints

    # An endpoint yaml exists in the Scout configuration paths (test/etc/AI,
    # ~/.scout/etc/AI, ...). Purely local: no network access.
    def endpoint_configured?(endpoint)
      memo(:"endpoint_configured_#{endpoint}") do
        Scout.etc.AI[endpoint.to_s].find_with_extension(:yaml).exists?
      end
    end

    # The endpoint points to a host:port that accepts a TCP connection within
    # the timeout. Only probed for endpoints whose config carries a url;
    # endpoints without a url (mock, relay through scp, ...) count as
    # reachable once configured.
    def endpoint_reachable?(endpoint, timeout = 5)
      memo(:"endpoint_reachable_#{endpoint}") do
        path = Scout.etc.AI[endpoint.to_s].find_with_extension(:yaml)
        return false unless path.exists?
        url = path.yaml[:url] || path.yaml['url']
        return true if url.nil?

        require 'uri'
        require 'socket'
        uri = URI.parse(url.to_s)
        port = uri.port || (uri.scheme == 'https' ? 443 : 80)
        begin
          Timeout.timeout(timeout) do
            TCPSocket.open(uri.host, port) { |s| s.close }
          end
          true
        rescue Exception
          false
        end
      end
    end

    # Combined: configured AND (no url OR reachable)
    def endpoint_available?(endpoint)
      return false unless endpoint_configured?(endpoint)
      endpoint_reachable?(endpoint)
    end

    def endpoint_reason(endpoint)
      return "endpoint #{endpoint} not configured (no yaml in the Scout AI paths)" unless endpoint_configured?(endpoint)
      return "endpoint #{endpoint} configured but not reachable" unless endpoint_reachable?(endpoint)
      nil
    end

    # All endpoint names defined in Scout.etc.AI across the search paths
    # (test/etc/AI plus the user configuration). Local filesystem only.
    def configured_endpoints
      memo(:configured_endpoints) do
        Scout.etc.AI.glob('*.yaml').collect { |f| File.basename(f, '.yaml') }.uniq
      end
    end

    # Endpoints that are real inference services (anything but the offline
    # mock one defined by this test suite).
    def real_endpoints
      memo(:real_endpoints) do
        configured_endpoints.reject { |e| e == 'mock' }
      end
    end

    #{{{ internals

    def which?(cmd)
      ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, cmd.to_s)
        File.executable?(path)
      end
    end

    # Runs cmd with a hard timeout. Returns [stdout, stderr, exit_status].
    # ScoutCoder: Open3.capture3 threads cannot be killed, so Timeout.timeout
    # only breaks the wait; the child is detached with Process.kill(:KILL) to
    # guarantee the probe returns even when the command hangs (e.g. a python
    # import that blocks on a broken environment).
    def run_bounded(cmd, timeout = DEFAULT_TIMEOUT, capture: true)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe

      pid = Process.spawn(*cmd, out: out_w, err: err_w)
      out_w.close
      err_w.close

      status = nil
      begin
        Timeout.timeout(timeout) do
          out = capture ? out_r.read : nil
          err = capture ? err_r.read : nil
          _pid, status = Process.wait2(pid)
          return [out.to_s, err.to_s, status.exitstatus]
        end
      rescue Timeout::Error
        begin
          Process.kill(:KILL, pid)
        rescue Errno::ESRCH
        end
        Process.detach(pid)
        return ['', 'timeout', -1]
      rescue Errno::ENOENT
        begin
          Process.kill(:KILL, pid)
        rescue Errno::ESRCH, Errno::EPERM
        end
        return ['', 'not found', -1]
      ensure
        out_r.close rescue nil
        err_r.close rescue nil
      end
      ['', 'unknown', -1]
    end
  end
end
