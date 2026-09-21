require "digest"
require "fileutils"
require "rbconfig"
require "tmpdir"
require "fiddle"
require "monitor"

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

      # Every generated object exports the same fixed names -- carray_jit_kernel,
      # carray_jit_slab, the border and error helpers -- because each one is a
      # module of its own.  Fiddle.dlopen passes RTLD_GLOBAL, so on ELF those
      # names all land in one flat namespace and an intra-module call resolves
      # to the first definition loaded: a later kernel's carray_jit_slab calls
      # an earlier kernel's carray_jit_kernel, which takes a different number
      # of operands, reads past the pointers it was given, and the process
      # segfaults.  -Wl,-Bsymbolic binds each object's own definitions before
      # the global scope, which is what one object per kernel assumed all
      # along.  Nothing else needs saying so: Mach-O binds within each dylib's
      # own two-level namespace and PE within each DLL, so the flag is named
      # only where it means something -- and Apple's linker rejects it
      # outright, which would trade a Linux crash for a macOS build that never
      # compiles at all.
      SYMBOLIC =
        (RbConfig::CONFIG["host_os"] =~ /darwin|mswin|mingw|cygwin/ ?
           [] : ["-Wl,-Bsymbolic"]).freeze

      FLAGS = ["-O3", "-fPIC", "-shared", "-ffp-contract=off", *SYMBOLIC].freeze

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
          ENV["CARRAY_JIT_CACHE"] || @cache_root ||
            File.join(ENV["XDG_CACHE_HOME"] || File.join(Dir.home, ".cache"),
                      "carray-jit")
        end

        # An application saying where its own kernels live, rather than
        # sharing the one cache under the home directory.  Set it before the
        # first kernel is compiled; kernels already loaded keep working, and
        # what is already on disk stays where it is.  `nil` restores the
        # default.
        #
        # The environment still comes first: `CARRAY_JIT_CACHE` redirects an
        # application that names a directory here, and `CARRAY_JIT_NO_CACHE`
        # takes the cache away, so whoever runs a program can still put it
        # somewhere writable, or do without.
        #
        # The path is expanded when it is given, not when it is read: a
        # relative one would otherwise name a different directory after the
        # program changes its working directory.
        def cache_root= (path)
          @cache_root = path && File.expand_path(path)
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
        # One compile at a time in a process.  The staging path a build
        # compiles to is named for the process, so two threads building at
        # once wrote the same file and whichever renamed first left the other
        # renaming a path that was gone -- a bare Errno::ENOENT out of three
        # threads in four.  Serialising them also spares the second thread the
        # build: it takes the lock after the first has renamed, and finds the
        # object where a later run would.  Reentrant, so that a build reached
        # from inside another -- which none is today -- would not stop here.
        LOCK = Monitor.new

        def build (source, function_name, header: nil, flags: FLAGS)
          LOCK.synchronize { build_locked(source, function_name, header: header, flags: flags) }
        end

        def build_locked (source, function_name, header: nil, flags: FLAGS)
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
          handle =
            begin
              compile(source_path, staging_path, flags)
              # Opened before it is published, under the name only this
              # process knows.  Published first, the object stands in the
              # cache for the moment between the rename and the open, and
              # another process pruning in that moment can evict it -- prune
              # spares what the process running it is building, which says
              # nothing about what anyone else is.  The build then failed to
              # load what it had just compiled.  Opened first, the image is
              # mapped and stays mapped whatever the directory does
              # afterwards, which is why evicting an object in use is safe.
              load_new_object(staging_path)
            rescue Exception
              # A build that did not finish leaves nothing behind.  The
              # source is half an entry: nothing looks it up -- a hit is an
              # object -- and prune globs objects too, so it would sit in the
              # cache for good, one per kernel per run against a toolchain
              # that cannot compile.  The staging file would be swept in five
              # minutes; it goes now, beside the source it came from.
              remove_entry(object_path)
              unlink(staging_path)
              raise
            end
          File.rename(staging_path, object_path)
          sweep_staging(directory)
          sweep_environments
          prune(directory, object_path)

          [handle, true]
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
          stat = File.stat(directory)
          if (stat.mode & 0022) != 0
            raise CompilationError,
                  "#{directory} is writable by other users; " \
                  "carray-jit loads shared objects from it. " \
                  "Fix its permissions or set CARRAY_JIT_CACHE elsewhere."
          end
          # And whose it is, not only who may write to it.  A directory of
          # someone else's is one they write to whatever its mode says, and
          # 0700 is what an attacker's own directory would be: a cache root
          # under a shared /tmp, where this user has yet to create the
          # directory for their environment, is a name someone else can take
          # first -- as a directory of their own, or as a symlink to one,
          # which the mode is then read through.  Followed on purpose: a
          # cache root symlinked to another volume is an ordinary
          # arrangement, and it is the owner that says whether it is ours.
          unless stat.uid == Process.euid
            raise CompilationError,
                  "#{directory} belongs to uid #{stat.uid}, not to this user " \
                  "(uid #{Process.euid}); carray-jit loads shared objects " \
                  "from it. Set CARRAY_JIT_CACHE to a directory of your own."
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
          [object_path, source_path].each { |path| unlink(path) }
        end

        def unlink (path)
          File.unlink(path) if File.exist?(path)
        rescue StandardError
          nil
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
          # Asked before the spawn, because a spawn that finds nothing raises
          # Errno::ENOENT naming the program and nothing else -- not what it
          # was wanted for, and not where to say so.  This is the same lookup
          # the key already makes to identify the compiler.
          unless resolve_compiler(compiler_command)
            raise CompilationError,
                  "`#{compiler_command}` is not an executable this process " \
                  "can find; carray-jit compiles its kernels with it. " \
                  "Set CARRAY_JIT_CC to a C compiler, or leave it unset for " \
                  "the one Ruby was built with."
          end
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
