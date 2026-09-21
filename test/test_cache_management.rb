require_relative "test_helper"
require "tmpdir"

# The cache outlives the process, so it has to be bounded and inspectable.
class TestCacheManagement < Minitest::Test

  def setup
    @previous_cache = ENV["CARRAY_JIT_CACHE"]
    @previous_limit = ENV["CARRAY_JIT_CACHE_LIMIT"]
    @previous_off = ENV["CARRAY_JIT_NO_CACHE"]
    @directory = Dir.mktmpdir("carray-jit-management-")
    ENV["CARRAY_JIT_CACHE"] = @directory
    CArray::JIT.clear_registry
  end

  def teardown
    ENV["CARRAY_JIT_CACHE"] = @previous_cache
    ENV["CARRAY_JIT_CACHE_LIMIT"] = @previous_limit
    ENV["CARRAY_JIT_NO_CACHE"] = @previous_off
    CArray::JIT.cache_root = nil
    CArray::JIT::Compiler.instance_variable_set(:@ephemeral_directory, nil)
    FileUtils.remove_entry(@directory) if File.directory?(@directory)
    CArray::JIT.clear_registry
  end

  # The directory kernels actually land in, under the root.
  def leaf
    CArray::JIT.cache_directory
  end

  def compile_indexed (index)
    compile_kernel("->(i) { a[i] = a[i-1] * #{index}.5 }", arrays: { :a => "float64" })
  end

  # -- where an application puts its own ----------------------------------

  def test_an_application_can_name_its_own_cache_root
    ENV.delete("CARRAY_JIT_CACHE")
    Dir.mktmpdir("carray-jit-application-") do |own|
      CArray::JIT.cache_root = own
      assert_equal(own, CArray::JIT.cache_root)
      compile_indexed(1)
      assert_equal(1, CArray::JIT.cache_entry_count)
      assert_equal(File.join(own, CArray::JIT::Compiler.environment_tag),
                   CArray::JIT.cache_directory)
    end
  end

  # Whoever runs the program has the last word on where a cache may be
  # written, and on whether there is one at all.
  def test_the_environment_comes_before_what_the_application_named
    Dir.mktmpdir("carray-jit-application-") do |own|
      CArray::JIT.cache_root = own
      assert_equal(@directory, CArray::JIT.cache_root)
      ENV["CARRAY_JIT_NO_CACHE"] = "1"
      refute_equal(own, CArray::JIT.cache_root)
    end
  end

  # A relative path is expanded when it is given.  Read later instead, it
  # would name a different directory once the program has moved.
  def test_a_relative_cache_root_is_settled_where_it_is_given
    ENV.delete("CARRAY_JIT_CACHE")
    Dir.mktmpdir("carray-jit-application-") do |own|
      here = Dir.chdir(own) { CArray::JIT.cache_root = "kernels"; Dir.pwd }
      assert_equal(File.join(here, "kernels"), CArray::JIT.cache_root)
    end
  end

  def test_nothing_named_is_the_cache_everything_shares
    ENV.delete("CARRAY_JIT_CACHE")
    Dir.mktmpdir("carray-jit-application-") do |own|
      CArray::JIT.cache_root = own
      CArray::JIT.cache_root = nil
      refute_equal(own, CArray::JIT.cache_root)
      assert_equal("carray-jit", File.basename(CArray::JIT.cache_root))
    end
  end

  def test_cache_reports_where_it_is_and_how_big
    compile_indexed(1)
    assert_equal(@directory, CArray::JIT.cache_root)
    assert_equal(File.join(@directory, CArray::JIT::Compiler.environment_tag),
                 CArray::JIT.cache_directory)
    assert_equal(1, CArray::JIT.cache_entry_count)
    assert_operator(CArray::JIT.cache_byte_size, :>, 0)
  end

  def test_source_is_kept_beside_the_object
    compile_indexed(2)
    sources = Dir[File.join(leaf, "*.c")]
    assert_equal(1, sources.size)
    assert_includes(File.read(sources.first), "carray_jit_kernel")
  end

  # Without a bound this is RubyInline's ~/.ruby_inline all over again: it
  # grows for the life of the account and nothing ever removes anything.
  def test_cache_is_pruned_to_the_limit
    ENV["CARRAY_JIT_CACHE_LIMIT"] = "3"
    6.times { |index| compile_indexed(index) }
    assert_operator(CArray::JIT.cache_entry_count, :<=, 3)
    assert_equal(CArray::JIT.cache_entry_count, Dir[File.join(leaf, "*.c")].size,
                 "sources and objects should be pruned together")
  end

  def test_pruning_keeps_the_most_recently_used
    ENV["CARRAY_JIT_CACHE_LIMIT"] = "2"
    first = compile_indexed(1)
    sleep(0.01)
    compile_indexed(2)
    sleep(0.01)
    # Reusing the first kernel marks it as recent, so the second should go.
    CArray::JIT.clear_registry
    reused = compile_kernel("->(i) { a[i] = a[i-1] * 1.5 }")
    refute(reused.compiled, "the first kernel should have come from the cache")
    sleep(0.01)
    compile_indexed(3)

    remaining = Dir[File.join(leaf, "*.c")].map { |path| File.read(path) }
    assert(remaining.any? { |source| source.include?("1.5") },
           "the recently reused kernel was evicted")
  end

  def test_clear_cache_empties_it
    compile_indexed(1)
    compile_indexed(2)
    removed = CArray::JIT.clear_cache
    assert_equal(2, removed)
    assert_equal(0, CArray::JIT.cache_entry_count)
    assert_empty(Dir[File.join(leaf, "*.c")])
  end

  # A loaded shared object keeps working after its file is gone, so clearing
  # the cache never breaks a kernel that is already in use.
  def test_kernel_still_runs_after_the_cache_is_cleared
    kernel = compile_indexed(1)
    CArray::JIT.clear_cache
    array = CArray.double(4)
    array[0] = 2.0
    kernel.call({ :a => array }, {}, [[1, 4, 1]])
    assert_equal(2.0 * 1.5 * 1.5 * 1.5, array[3])
  end

  def test_ephemeral_cache_uses_a_temporary_directory
    ENV["CARRAY_JIT_NO_CACHE"] = "1"
    CArray::JIT::Compiler.instance_variable_set(:@ephemeral_directory, nil)
    assert(CArray::JIT::Compiler.ephemeral?)
    directory = CArray::JIT.cache_directory
    refute_equal(@directory, directory)
    assert_includes(directory, File.basename(Dir.tmpdir))
    compile_indexed(9)
    assert_equal(1, CArray::JIT.cache_entry_count)
  end

  # Everything in the cache gets dlopen'd, so a directory other users can
  # write to would let them run code as this user.
  def test_world_writable_cache_is_refused
    FileUtils.mkdir_p(leaf)
    FileUtils.chmod(0777, leaf)
    error = assert_raises(CArray::JIT::CompilationError) { compile_indexed(4) }
    assert_match(/writable by other users/, error.message)
  ensure
    FileUtils.chmod(0700, leaf) if File.directory?(leaf)
  end

  # The cache outlives the process, so an entry that cannot be loaded would
  # otherwise fail every future run as well, not just this one.
  def test_unusable_cache_entry_is_rebuilt
    source = "->(i) { a[i] = a[i-1] * 11.0 }"
    compile_kernel(source)
    object = Dir[File.join(leaf, "*")].find { |path| !path.end_with?(".c") }

    # A second root, so the path is one dyld has not already loaded in this
    # process -- otherwise it would hand back the cached image and the corrupt
    # file would never be read.  The entry is planted under the name the build
    # looks up, which is the name it wrote here: the key is a digest of the
    # source the kernel is built from, which is neither `c_source` nor what
    # `c_source` digests to, so computing one here is how this test came to
    # plant its file where nothing would ever look.
    # Two of them, because dyld hands back the image it already has for a
    # path: the good copy below would be answered from memory, corrupt file
    # or not, if both entries stood at one path.
    good = plant(object, Dir.mktmpdir("carray-jit-good-"))
    other = Dir.mktmpdir("carray-jit-corrupt-")
    planted = plant(object, other)

    # The name is the one consulted: a good copy under it is reused rather
    # than built again.  Without this the corrupt entry below could sit
    # unread and the rebuild look like a rebuild of nothing.
    ENV["CARRAY_JIT_CACHE"] = File.dirname(File.dirname(good))
    CArray::JIT.clear_registry
    refute(compile_kernel(source).compiled,
           "a good entry under this name should be reused")

    File.write(planted, "not a shared object")
    ENV["CARRAY_JIT_CACHE"] = other
    CArray::JIT.clear_registry
    rebuilt = compile_kernel(source)
    assert(rebuilt.compiled, "a corrupt cache entry should be rebuilt")
    assert_operator(File.size(planted), :>, "not a shared object".bytesize,
                    "the corrupt entry should have been replaced")

    array = CArray.double(3)
    array[0] = 1.0
    rebuilt.call({ :a => array }, {}, [[1, 3, 1]])
    assert_equal(121.0, array[2])
  ensure
    [other, good && File.dirname(File.dirname(good))].each do |directory|
      FileUtils.remove_entry(directory) if directory && File.directory?(directory)
    end
  end

  # A copy of `object` under the same name, in a root of its own.
  def plant (object, root)
    FileUtils.chmod(0700, root)
    directory = File.join(root, File.basename(leaf))
    FileUtils.mkdir_p(directory, :mode => 0700)
    path = File.join(directory, File.basename(object))
    FileUtils.cp(object, path)
    path
  end

  # A process killed mid-compile leaves a staging file that matches neither
  # the entry glob nor the prune glob.
  def test_abandoned_staging_files_are_swept
    FileUtils.mkdir_p(leaf)
    # sweep_staging globs "*<suffix>.<pid>", so a staging file only matches
    # when it carries this platform's suffix -- ".so" here, ".bundle" on macOS.
    suffix = CArray::JIT::Compiler.send(:shared_object_suffix)
    stale = File.join(leaf, "deadbeef#{suffix}.99999")
    fresh = File.join(leaf, "cafe#{suffix}.99998")
    FileUtils.touch(stale)
    FileUtils.touch(fresh)
    File.utime(Time.now - 3600, Time.now - 3600, stale)

    compile_indexed(7)

    refute(File.exist?(stale), "an abandoned staging file should be swept")
    assert(File.exist?(fresh), "a staging file young enough to be in use should stay")
  end

  # Reusing objects a different toolchain produced is exactly what a cache
  # shared across processes and time would otherwise do.
  def test_compiler_identity_is_part_of_the_key
    source = "int main(void) { return 0; }"
    CArray::JIT::Compiler.instance_variable_set(:@compiler_identity, nil)
    first = CArray::JIT::Compiler.digest(source)
    ENV["CARRAY_JIT_CC"] = "/usr/bin/false"
    CArray::JIT::Compiler.instance_variable_set(:@compiler_identity, nil)
    second = CArray::JIT::Compiler.digest(source)
    refute_equal(first, second)
  ensure
    ENV.delete("CARRAY_JIT_CC")
    CArray::JIT::Compiler.instance_variable_set(:@compiler_identity, nil)
  end

  # An object is opened before it is published, so that eviction cannot come
  # between the build and the open.  Another process's prune spares only what
  # that process is building, and with a limit below the number of processes
  # building at once it evicted theirs: every one of five processes failed at
  # a limit of 2, with "could not load freshly compiled".
  def test_building_while_another_process_evicts
    skip "fork is not available here" unless Process.respond_to?(:fork)
    ENV["CARRAY_JIT_CACHE_LIMIT"] = "1"
    pids = 3.times.map { |p|
      fork do
        status = 0
        2.times do |r|
          begin
            CArray::JIT.clear_registry
            compile_kernel("->(i) { a[i] = a[i-1] * 1#{p}#{r}.5 }")
          rescue Exception
            status = 1
          end
        end
        exit status
      end
    }
    failed = pids.count { |pid| Process.wait2(pid)[1].exitstatus != 0 }
    assert_equal(0, failed, "a build should not lose to another's eviction")
  ensure
    ENV.delete("CARRAY_JIT_CACHE_LIMIT")
  end

  # A build that fails leaves no half of an entry behind: a source with no
  # object is never looked up and never pruned, so one would stay for good,
  # and one more with every kernel of every run.
  def test_a_failed_build_leaves_nothing_in_the_cache
    ENV["CARRAY_JIT_CC"] = "/usr/bin/false"
    CArray::JIT::Compiler.instance_variable_set(:@compiler_identity, nil)
    CArray::JIT.clear_registry
    assert_raises(CArray::JIT::CompilationError) { compile_indexed(7) }
    assert_empty(Dir[File.join(leaf, "*")],
                 "a failed build should leave no source and no staging file")
  ensure
    ENV.delete("CARRAY_JIT_CC")
    CArray::JIT::Compiler.instance_variable_set(:@compiler_identity, nil)
    CArray::JIT.clear_registry
  end

  # A compiler that is not there is said once, where it is looked for --
  # rather than as an Errno::ENOENT out of the spawn, naming the program and
  # neither what it was for nor the variable that names it.
  def test_a_compiler_that_is_not_there_says_so
    ENV["CARRAY_JIT_CC"] = "carray-jit-no-such-compiler"
    CArray::JIT::Compiler.instance_variable_set(:@compiler_identity, nil)
    CArray::JIT.clear_registry
    error = assert_raises(CArray::JIT::CompilationError) { compile_indexed(6) }
    assert_match(/carray-jit-no-such-compiler/, error.message)
    assert_match(/CARRAY_JIT_CC/, error.message)
  ensure
    ENV.delete("CARRAY_JIT_CC")
    CArray::JIT::Compiler.instance_variable_set(:@compiler_identity, nil)
    CArray::JIT.clear_registry
  end

  # The mode says who may write; the owner says whose it is.  A directory
  # belonging to someone else is one they write to whatever its mode says,
  # and 0700 is what theirs would be -- so a cache root in a shared place,
  # whose environment directory this user has yet to create, is a name
  # someone else can take first and have its contents dlopen'd.
  def test_a_cache_directory_of_another_user_is_refused
    FileUtils.mkdir_p(leaf, :mode => 0700)
    # Someone else's directory, arrived at from the other side: this process
    # is someone else.  Owning the directory for real would take two users.
    original = Process.method(:euid)
    Process.define_singleton_method(:euid) { original.call + 1 }
    begin
      error = assert_raises(CArray::JIT::CompilationError) { compile_indexed(8) }
      assert_match(/belongs to uid/, error.message)
      assert_match(/CARRAY_JIT_CACHE/, error.message)
    ensure
      Process.define_singleton_method(:euid, original)
    end
  end

  # A root symlinked elsewhere -- another volume, a different disk -- is an
  # ordinary arrangement, and the link is followed as it always was: what is
  # asked about is the directory it lands on.
  def test_a_symlinked_cache_root_still_works
    elsewhere = Dir.mktmpdir("carray-jit-elsewhere-")
    FileUtils.chmod(0700, elsewhere)
    root = Dir.mktmpdir("carray-jit-link-")
    link = File.join(root, "cache")
    File.symlink(elsewhere, link)
    ENV["CARRAY_JIT_CACHE"] = link
    CArray::JIT.clear_registry
    compile_indexed(9)
    refute_empty(Dir[File.join(elsewhere, "*", "*")],
                 "the kernel should be cached through the link")
  ensure
    [elsewhere, root].each do |directory|
      FileUtils.remove_entry(directory) if directory && File.directory?(directory)
    end
  end

  def test_cache_directory_is_created_private
    nested = File.join(@directory, "created")
    ENV["CARRAY_JIT_CACHE"] = nested
    compile_indexed(5)
    assert_equal(0700, File.stat(CArray::JIT.cache_directory).mode & 0777)
  end

end
