# Shared path grants and filesystem-containment policy for LLM callers.
# This policy answers whether a path is within an explicitly supplied root or
# grant; it does not check OS permissions or open the path.
module LLM
  module Sandbox
    Decision = Struct.new(:allowed, :path, :canonical_path, :exists, :grant, :reason, keyword_init: true)

    module_function

    # Resolve a filesystem spelling without Scout Path#find's resource-map
    # behavior. Existing components are realpathed one at a time so symlinks
    # (including a symlinked parent of a missing target) affect containment.
    # Missing components are retained lexically beneath the resolved ancestor.
    def resolve_path(path, base_path: nil)
      spelling = path.to_s
      raise ParameterException, 'path must not be empty' if spelling.empty?
      unless spelling.start_with?(File::SEPARATOR)
        raise ParameterException, 'relative paths require an explicit base_path' unless base_path
        raise ParameterException, 'base_path must be absolute' unless base_path.to_s.start_with?(File::SEPARATOR)
      end

      absolute = spelling.start_with?(File::SEPARATOR) ? spelling : File.join(base_path.to_s, spelling)
      current = File::SEPARATOR
      exists = true
      absolute.split(File::SEPARATOR).each do |component|
        next if component.empty? || component == '.'
        if component == '..'
          # A path walk cannot reach a later '..' after a missing component;
          # collapsing it lexically could authorize a target the OS cannot
          # resolve (and could conceal traversal through an absent parent).
          return {path: spelling, canonical_path: nil, exists: false} unless exists
          # `..` is only traversable when the preceding component is a
          # directory. Otherwise the original spelling fails with ENOTDIR,
          # even though taking dirname would produce a plausible target.
          begin
            directory = Open.directory?(current)
          rescue SystemCallError => error
            return {path: spelling, canonical_path: nil, exists: false, error: error}
          end
          return {path: spelling, canonical_path: nil, exists: false, error: Errno::ENOTDIR.new(current)} unless directory
          current = File.dirname(current)
          next
        end

        candidate = File.join(current, component)
        begin
          File.lstat(candidate)
          begin
            current = File.realpath(candidate)
          rescue SystemCallError => error
            # A dangling symlink or otherwise unresolvable existing component
            # is not safe to treat as a missing lexical path.
            return {path: spelling, canonical_path: nil, exists: false, error: error}
          end
        rescue Errno::ENOENT
          current = candidate
          exists = false
        rescue SystemCallError => error
          # In particular, ENOTDIR and EACCES are not missing targets: fail
          # closed instead of treating an unresolvable parent as lexical space.
          return {path: spelling, canonical_path: nil, exists: false, error: error}
        end
      end

      {path: spelling, canonical_path: current, exists: exists}
    rescue SystemCallError => error
      {path: spelling, canonical_path: nil, exists: false, error: error}
    end

    # mode=:read accepts root, writable grants, and read grants. mode=:write
    # accepts only root and writable grants. Root and grant paths are themselves
    # resolved using resolve_path, so a symlink cannot make a grant escape its
    # physical target. Relative inputs require base_path: relative to Dir.pwd
    # would make decisions depend on ambient process state. Missing targets are
    # checked against their resolved existing ancestor plus remaining components.
    def authorize_path(path, root: Dir.pwd, writable_paths: [], read_paths: [], mode: :read, base_path: nil)
      raise ParameterException, "unsupported path access mode: #{mode.inspect}" unless [:read, :write].include?(mode.to_sym)

      target = resolve_path(path, base_path: base_path)
      unless target[:canonical_path]
        return Decision.new(allowed: false, path: path.to_s, canonical_path: nil,
                            exists: false, grant: nil, reason: :unresolvable)
      end

      policies = [[:root, root], *Array(writable_paths).map { |grant| [:writable, grant] }]
      policies.concat(Array(read_paths).map { |grant| [:read, grant] }) if mode.to_sym == :read
      policies.each do |kind, grant_path|
        grant = resolve_path(grant_path, base_path: base_path)
        next unless grant[:canonical_path]
        next unless inside?(target[:canonical_path], grant[:canonical_path])

        return Decision.new(allowed: true, path: path.to_s,
                            canonical_path: target[:canonical_path], exists: target[:exists],
                            grant: kind, reason: :contained)
      end

      Decision.new(allowed: false, path: path.to_s,
                   canonical_path: target[:canonical_path], exists: target[:exists],
                   grant: nil, reason: :outside_grants)
    end

    # Boundary-aware containment: /a/b is inside /a, but /a-b is not.
    def inside?(path, root)
      path == root || path.start_with?(root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR)
    end

    # -------------------------------------------------------------------------
    # Grant sources
    #
    # The containment policy above takes grants as explicit inputs and never
    # reads configuration. This section is the shared layer that COMPOSES
    # those inputs from Scout::Config, the environment, and the thread-local
    # registrar below, so sandboxed workflows share one grant vocabulary
    # instead of each growing its own copy of a get_allowed_paths method.
    # -------------------------------------------------------------------------

    # Config key -> default grant list. The keys double as the environment
    # variable names (ALLOWED_PATHS, DIRS, ...). The 'thread' sources read
    # the live thread keys, the same keys the allow_path/allow_read_path
    # registrar writes, so registered job paths and configured grants meet
    # in one list.
    def self.grant_type_defaults
      {
        'exec_paths'         => '/bin:/usr:/lib:/lib64:/etc',
        'allowed_paths'      => (Path.setup('tmp').find_all + ['/tmp', '~/tmp']).join(':'),
        'allowed_read_paths' => '',
        'dirs'               => '',
        'read_paths'         => '',
        'thread'             => Thread.current['allowed_paths'],
        'thread_read'        => Thread.current['allowed_read_paths']
      }
    end

    # Token chain for one workflow scope: ['Workspace', 'workspace',
    # 'sandbox']. Scout::Config gives untyped tokens a better priority than
    # the plain key, so an entry tokened with the workflow or 'sandbox'
    # overrides an untokened entry for the same key.
    def self.grant_scope_tokens(scope)
      return ['sandbox'] if scope.nil?
      scope = scope.to_s
      [scope, Misc.snake_case(scope), 'sandbox']
    end

    # ScoutCoder: Scout::Config.get requires at least one token when called
    # with a symbol key (an empty-token call builds "key:" + key and raises
    # TypeError on symbols); the :env option only replaces the DEFAULT, so a
    # config entry beats the environment variable; tokened entries beat
    # untokened key entries because untyped tokens carry priority 10 against
    # the implicit key token's 20.
    def self.grant_paths(type, scope: nil)
      type = type.to_s
      value = Scout::Config.get(type, *grant_scope_tokens(scope),
                                default: grant_type_defaults[type],
                                env: type.upcase)
      return [] if value.nil?
      dirs = String === value ? value.split(/[,:]/) : value
      Array(dirs).collect { |dir| expand_grant_path(dir) }.flatten
    end

    # Located spellings (absolute or '~/...') expand as-is; unlocated Scout
    # path spellings (e.g. 'tmp') resolve through the Scout path maps with
    # find_all instead of being anchored to the process working directory.
    def self.expand_grant_path(dir)
      path = Path.setup(dir.to_s)
      return Path.setup(File.expand_path(path)) if path.located?
      path.find_all
    end

    def self.writable_grants(scope: nil)
      grant_paths('allowed_paths', scope: scope) +
        grant_paths('dirs', scope: scope) +
        grant_paths('thread', scope: scope)
    end

    def self.readable_grants(scope: nil)
      grant_paths('allowed_read_paths', scope: scope) +
        grant_paths('exec_paths', scope: scope) +
        grant_paths('read_paths', scope: scope) +
        grant_paths('thread_read', scope: scope)
    end

    # Which grant source first lists +path+ (expanded-spelling equality,
    # not containment). Mirrors the origin vocabulary of the sandbox
    # introspection tasks: root, dirs, allowed_paths, thread, exec_paths,
    # read_paths, allowed_read_paths, thread_read, bwrap_paths,
    # bwrap_read_paths.
    def self.grant_origin(path, scope: nil, root: nil)
      expanded = File.expand_path(path.to_s)
      sources = {
        root: root ? [root.to_s] : [],
        dirs: grant_paths('dirs', scope: scope),
        allowed_paths: grant_paths('allowed_paths', scope: scope),
        thread: grant_paths('thread', scope: scope),
        exec_paths: grant_paths('exec_paths', scope: scope),
        read_paths: grant_paths('read_paths', scope: scope),
        allowed_read_paths: grant_paths('allowed_read_paths', scope: scope),
        thread_read: grant_paths('thread_read', scope: scope),
        bwrap_paths: grant_paths('bwrap_paths', scope: scope),
        bwrap_read_paths: grant_paths('bwrap_read_paths', scope: scope)
      }
      sources.each do |origin, paths|
        next if paths.nil?
        candidates = Array(paths).collect do |p|
          begin
            File.expand_path(p.to_s)
          rescue
            p.to_s
          end
        end
        return origin if candidates.include?(expanded)
      end
      nil
    end

    # One line per grant, annotated read-write or read-only, for denial
    # messages and introspection output. +hint+ is appended verbatim as the
    # last line (callers name their own introspection task).
    def self.describe_grants(scope: nil, root: nil, hint: nil)
      writable = [root, writable_grants(scope: scope)].flatten.compact.uniq.collect { |p| File.expand_path(p.to_s) }
      readable = readable_grants(scope: scope).flatten.compact.uniq.collect { |p| File.expand_path(p.to_s) }
      lines = writable.collect { |p| "#{p} (read-write)" }
      lines.concat((readable - writable).collect { |p| "#{p} (read-only)" })
      text = (lines * "\n    ")
      text += "\n  #{hint}" if hint
      text
    end

    # These registrations intentionally preserve the existing Chat thread keys
    # and raw path spellings for callers that inspect or serialize the grants.
    def allow_path(path)
      Thread.current['allowed_paths'] ||= []
      return if Thread.current['allowed_paths'].include?(path)
      Log.medium "Allow #{path}"
      Thread.current['allowed_paths'] << path
    end

    def allow_read_path(path)
      Thread.current['allowed_read_paths'] ||= []
      return if Thread.current['allowed_read_paths'].include?(path)
      Log.medium "Allow read #{path}"
      Thread.current['allowed_read_paths'] << path
    end

    def allow_job(job)
      allow_path(job.path)
      allow_path(job.info_file)
      allow_path(job.files_dir)
    end

    def allow_read_job(job)
      allow_read_path(job.path)
      allow_read_path(job.info_file)
      allow_read_path(job.files_dir)
    end
  end
end

# ScoutCoder: File.realpath must be applied component-by-component: resolving
# only the nearest existing parent lexically would mishandle symlink/../ paths.
# Missing descendants retain the canonical spelling of their existing parent.
