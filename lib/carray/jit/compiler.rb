require "digest"
require "fileutils"
require "rbconfig"
require "tmpdir"
require "fiddle"

class CArray
  module JIT

    # Compiles generated C into a shared object and hands back a loaded
    # function pointer, caching by the hash of the source and the flags used
    # to build it.
    #
    # The cache is on disk and outlives the process because rebuilding is not
    # cheap: about 60 ms to compile, plus roughly 180 ms on macOS the first
    # time a freshly written binary is loaded, which is Gatekeeper checking it
    # rather than anything Ruby does.  A second process loading the same file
    # pays 0.2 ms.  It is bounded, though -- see #prune -- so it cannot grow
    # without limit the way RubyInline's ~/.ruby_inline does.
    class Compiler

      # -ffp-contract=off is not optional.  Without it clang and gcc fuse
      # `a*b + c` into a single FMA -- even at -O0 on arm64 -- which changes
      # the last bit of the result and breaks agreement with the Ruby
      # evaluator.  Measured: a two-term recurrence diverges in 13 of 24
      # cells with contraction on, and matches bit for bit with it off.
      #
      # -O3 rather than -O2, which is what this was until it was measured.
      # The level is what decides whether the loop is vectorised at all, and
      # that is not a clang-shaped question: clang vectorises at -O2 already,
      # so on arm64 the change is worth 1.33x on an element-wise pass and
      # nothing on the rest (seven benchmarks, min of three, none slower).
      # gcc does not vectorise at -O2 at all -- measured 1.6x to 1.7x on the
      # same kernels -- so at -O2 this gem was leaving that on the table
      # wherever gcc is the compiler.  Compiling costs the same either way:
      # 57 ms against 58 ms on a generated kernel, min of seven.
      #
      # It is also what CArray builds itself with, and what this gem's own
      # fuse path already inherits from CArray::BUILD_FLAGS.  The kernel path
      # being lower was not a decision -- the flag list is the one the first
      # milestone was scaffolded with, and only the contraction flag beside
      # it was ever argued for.
      FLAGS = ["-O3", "-fPIC", "-shared", "-ffp-contract=off"].freeze

      # Kernels retained on disk.  Each costs about 17 KB, so the default is
      # roughly 9 MB -- far more than any real program compiles, but a bound
      # all the same.
      DEFAULT_ENTRY_LIMIT = 512

      class << self

        def compiler_command
          ENV["CARRAY_JIT_CC"] || RbConfig::CONFIG["CC"] || "cc"
        end

        # True when the cache lives in a temporary directory that goes away
        # with the process.
        def ephemeral?
          !ENV["CARRAY_JIT_NO_CACHE"].nil? || ENV["CARRAY_JIT_CACHE"] == "none"
        end

        # The root holds one directory per environment; kernels live in the
        # directory for this one.
        def cache_root
          return ephemeral_directory if ephemeral?
          ENV["CARRAY_JIT_CACHE"] ||
            File.join(ENV["XDG_CACHE_HOME"] || File.join(Dir.home, ".cache"),
                      "carray-jit")
        end

        def cache_directory
          File.join(cache_root, environment_tag)
        end

        # Kernels are only good for the version that generated them and the
        # architecture they were built for.  Keeping those apart means a new
        # release does not spend its cache budget on entries nothing can
        # reach any more, and a home directory shared between machines --
        # over NFS, or between Rosetta and native -- does not have one
        # architecture evicting the other's kernels.
        #
        # CArray's version is in it because a kernel is not only generated for
        # this library: it is handed CArray's memory, on layouts CArray
        # decides, and reaches CArray's own C by address.  A kernel that
        # compiles against one version and runs against the next is a silent
        # wrong answer rather than a load error, so the two versions travel
        # together.
        def environment_tag
          "#{JIT::VERSION}-carray#{carray_version}-#{RbConfig::CONFIG['arch']}"
        end

        # CArray's own version is defined by its extension, and this may be
        # running without it: the command that looks after the cache loads the
        # compiler and nothing else, on purpose, so that a cache can be
        # inspected or cleared when CArray itself will not load.  RubyGems
        # knows which version a `require` would activate without activating
        # it, and that is the same one -- except where CArray is on the load
        # path from a checkout, which nothing outside the process could have
        # known either way.
        def carray_version
          return CArray::VERSION if defined?(CArray::VERSION)
          return @carray_version if defined?(@carray_version)
          @carray_version =
            if defined?(Gem::Specification)
              begin
                Gem::Specification.find_by_name("carray").version.to_s
              rescue StandardError
                "none"
              end
            else
              "none"
            end
        end

        # Directories for versions and architectures no longer in use, so
        # they can be reported and removed as a unit.
        def stale_environments
          root = cache_root
          return [] unless File.directory?(root)
          current = cache_directory
          Dir[File.join(root, "*")].select { |path|
            File.directory?(path) && path != current
          }
        end

        def entry_limit
          limit = ENV["CARRAY_JIT_CACHE_LIMIT"]
          limit ? limit.to_i : DEFAULT_ENTRY_LIMIT
        end

        def entries
          Dir[File.join(cache_directory, "*#{shared_object_suffix}")]
        end

        def entry_count
          entries.size
        end

        def byte_size
          Dir[File.join(cache_directory, "*")].sum do |path|
            File.file?(path) ? File.size(path) : 0
          end
        end

        # Safe even while a kernel from the cache is in use: unlinking a
        # loaded shared object leaves the mapping intact.
        #
        # Clears this environment's kernels; pass everything: true to remove
        # the directories other versions and architectures left behind too.
        def clear (everything: false)
          removed = clear_directory(cache_directory)
          if everything
            stale_environments.each do |path|
              removed += Dir[File.join(path, "*#{shared_object_suffix}")].size
              begin
                FileUtils.remove_entry(path)
              rescue StandardError
                nil
              end
            end
          end
          removed
        end

        # Returns [Fiddle handle, whether it was compiled rather than reused].
        #
        # `header` says where the kernel was written.  It is written into the
        # .c file but kept out of the digest: two call sites that produce the
        # same kernel are one cached object, and editing the lines above a
        # kernel does not throw its object away.  The file then names the
        # first site that compiled it, which is a place the code was written
        # rather than the only one.
        def build (source, function_name, header: nil, flags: FLAGS)
          dump(header.to_s + source)

          directory = prepare(cache_directory)
          key = digest(source, flags)
          object_path = File.join(directory, "#{key}#{shared_object_suffix}")

          if File.exist?(object_path)
            handle = load_shared_object(object_path)
            if handle
              touch(object_path)
              return [handle, false]
            end
            # The cached object is unusable -- a truncated write, a toolchain
            # or OS change.  Since the cache outlives the process, failing
            # here would fail every future run as well, so drop it and build
            # again.
            remove_entry(object_path)
          end

          source_path = File.join(directory, "#{key}.c")
          File.write(source_path, header.to_s + source)
          # Build to a unique path and rename, so a concurrent process never
          # loads a half-written object.
          staging_path = "#{object_path}.#{Process.pid}"
          compile(source_path, staging_path, flags)
          File.rename(staging_path, object_path)
          sweep_staging(directory)
          sweep_environments
          prune(directory, object_path)

          [load_new_object(object_path), true]
        end

        # The flags are part of the key: the same C built two ways is two
        # objects, and need not compute the same last bit.
        def digest (source, flags = FLAGS)
          Digest::SHA256.hexdigest([source,
                                    compiler_identity,
                                    flags.join(" "),
                                    RbConfig::CONFIG["arch"],
                                    target_identity(flags)].join("\0"))
        end

        # Flags that mean "this machine" rather than a named target.  What
        # they select is not in the flag's text, so it is not in the key
        # either unless it is asked for.
        NATIVE_FLAGS = /\A-m(?:arch|cpu|tune)=native\z/

        # What `-march=native` actually chose, for the key.
        #
        # Without this, two machines can agree on every other component --
        # the same source, the same `arch` (`x86_64-linux` spans Nehalem to
        # Sapphire Rapids), the same flag *text*, and the same compiler,
        # since #compiler_identity is a stat of a binary that a shared /usr
        # or a common image makes identical -- and disagree only on which
        # instructions exist.  The one with the wider CPU writes an object
        # the other then loads and executes.  The cache directory is split
        # by `arch` with a shared home in mind (see #environment_tag); this
        # is the same care one level down.
        #
        # Asked of the compiler rather than the CPU, because what matters is
        # what the compiler will emit, and it is the only thing that knows.
        # The predefined macros carry the target triple and the instruction
        # sets together, so one probe answers all of it.
        #
        # Costs a compiler run, so it is only paid when a flag actually says
        # `native` -- the kernel path names no such flag and pays nothing --
        # and then once per process for each set of flags.
        def target_identity (flags)
          native = flags.select { |flag| flag =~ NATIVE_FLAGS }
          return "" if native.empty?

          command = compiler_command
          key = [command, native]
          cached = @target_identity
          return cached[1] if cached && cached[0] == key

          macros = probe_macros(command, native)
          identity = macros ? Digest::SHA256.hexdigest(macros)[0, 16] : "unprobed"
          @target_identity = [key, identity]
          identity
        end

        # The macros the compiler predefines for this target, sorted so that
        # the order it prints them in cannot make two identical targets look
        # different.  A compiler that will not answer leaves the key saying
        # so, which is worse than a real answer and better than a key that
        # silently claims two machines are one.
        def probe_macros (command, native)
          argv = [*command.split, *native, "-E", "-dM", "-x", "c", "/dev/null"]
          output = IO.popen(argv, err: File::NULL) { |io| io.read }
          return nil unless $?&.success?
          output.lines.sort.join
        rescue SystemCallError, IOError
          nil
        end

        # The compiler's name is not enough to key on: a cache shared with a
        # toolchain upgrade would keep handing back objects the old compiler
        # produced.  Its size and mtime stand in for a version, and cost a
        # stat rather than the ~50 ms of asking it with --version.
        def compiler_identity
          command = compiler_command
          cached = @compiler_identity
          return cached[1] if cached && cached[0] == command

          path = resolve_compiler(command)
          identity =
            if path
              stat = File.stat(path)
              "#{path}:#{stat.size}:#{stat.mtime.to_i}"
            else
              command
            end
          @compiler_identity = [command, identity]
          identity
        end

        def resolve_compiler (command)
          program = command.split.first
          return nil unless program
          if program.include?(File::SEPARATOR)
            return File.executable?(program) ? program : nil
          end
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
            candidate = File.join(directory, program)
            return candidate if File.file?(candidate) && File.executable?(candidate)
          end
          nil
        end

        private

        def clear_directory (directory)
          return 0 unless File.directory?(directory)
          removed = Dir[File.join(directory, "*#{shared_object_suffix}")].size
          Dir[File.join(directory, "*")].each do |path|
            File.unlink(path) if File.file?(path)
          end
          removed
        end

        def ephemeral_directory
          @ephemeral_directory ||= begin
            directory = Dir.mktmpdir("carray-jit-")
            at_exit do
              begin
                FileUtils.remove_entry(directory)
              rescue StandardError
                nil
              end
            end
            directory
          end
        end

        # 0700, and refuse a directory others can write to: everything in here
        # gets dlopen'd, so a shared writable cache is a way to run code as
        # this user.
        def prepare (directory)
          FileUtils.mkdir_p(directory, :mode => 0700) unless File.directory?(directory)
          mode = File.stat(directory).mode
          if (mode & 0022) != 0
            raise CompilationError,
                  "#{directory} is writable by other users; " \
                  "carray-jit loads shared objects from it. " \
                  "Fix its permissions or set CARRAY_JIT_CACHE elsewhere."
          end
          directory
        end

        # Least-recently-used eviction, by modification time, which #touch
        # keeps current on every reuse.
        def prune (directory, keep)
          limit = entry_limit
          return if limit <= 0
          objects = Dir[File.join(directory, "*#{shared_object_suffix}")]
          return if objects.size <= limit

          ordered = objects.sort_by { |path| File.mtime(path) rescue Time.at(0) }
          (ordered - [keep]).first(objects.size - limit).each do |path|
            remove_entry(path)
          end
        end

        # A process killed mid-compile leaves `<key>.bundle.<pid>` behind.
        # Those match neither the entry glob nor the prune glob, so without
        # this they would sit in the cache for good.  Only swept on a miss,
        # to keep it off the reuse path.
        STAGING_MAXIMUM_AGE = 300

        def sweep_staging (directory)
          now = Time.now
          Dir[File.join(directory, "*#{shared_object_suffix}.*")].each do |path|
            next unless File.file?(path)
            age = now - File.mtime(path) rescue 0
            next if age < STAGING_MAXIMUM_AGE
            begin
              File.unlink(path)
            rescue StandardError
              nil
            end
          end
        end

        # How long an unused environment's directory is kept.  A release or an
        # architecture that stops being used would otherwise sit in the cache
        # for good, since nothing in it is ever reached again.
        DEFAULT_ENVIRONMENT_MAXIMUM_AGE = 30 * 24 * 60 * 60

        def environment_maximum_age
          days = ENV["CARRAY_JIT_CACHE_MAX_AGE_DAYS"]
          days ? days.to_i * 24 * 60 * 60 : DEFAULT_ENVIRONMENT_MAXIMUM_AGE
        end

        def sweep_environments
          age = environment_maximum_age
          return if age <= 0
          now = Time.now
          stale_environments.each do |path|
            # A directory's own mtime only moves when entries are added or
            # removed, so age it by its newest file instead: one that is
            # being reused, and therefore touched, stays.
            newest = Dir[File.join(path, "*")].map { |entry|
              File.mtime(entry) rescue Time.at(0)
            }.max
            next if newest && (now - newest) < age
            begin
              FileUtils.remove_entry(path)
            rescue StandardError
              nil
            end
          end
        end

        def remove_entry (object_path)
          source_path = object_path.sub(/#{Regexp.escape(shared_object_suffix)}\z/, ".c")
          [object_path, source_path].each do |path|
            begin
              File.unlink(path) if File.exist?(path)
            rescue StandardError
              nil
            end
          end
        end

        def touch (path)
          now = Time.now
          File.utime(now, now, path)
        rescue StandardError
          nil
        end

        def dump (source)
          return unless ENV["CARRAY_JIT_DUMP"]
          warn("--- carray-jit generated source ---")
          warn(source)
          warn("-----------------------------------")
        end

        def shared_object_suffix
          RbConfig::CONFIG["DLEXT"] ? ".#{RbConfig::CONFIG['DLEXT']}" : ".so"
        end

        def compile (source_path, object_path, flags = FLAGS)
          command = [compiler_command, *flags, source_path, "-o", object_path, "-lm"]
          output = IO.popen(command, err: [:child, :out]) { |io| io.read }
          unless $?.success?
            raise CompilationError, "#{command.join(' ')}\n#{output}"
          end
        end

        # Returns nil rather than raising, so a bad cache entry can be
        # rebuilt.  A freshly compiled object that will not load is a real
        # failure and is raised by #load_new_object.
        def load_shared_object (path)
          Fiddle.dlopen(path)
        rescue Fiddle::DLError
          nil
        end

        def load_new_object (path)
          handle = load_shared_object(path)
          unless handle
            raise CompilationError, "could not load freshly compiled #{path}"
          end
          handle
        end

      end

    end

  end
end
