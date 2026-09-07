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
    kernel = compile_kernel(source)
    key = CArray::JIT::Compiler.digest(kernel.c_source)

    # A second directory, so the path is one dyld has not already loaded in
    # this process -- otherwise it would hand back the cached image and the
    # corrupt file would never be read.
    other = Dir.mktmpdir("carray-jit-corrupt-")
    FileUtils.chmod(0700, other)
    suffix = File.extname(Dir[File.join(leaf, "*")].find { |path|
      !path.end_with?(".c") })
    File.write(File.join(other, "#{key}#{suffix}"), "not a shared object")

    ENV["CARRAY_JIT_CACHE"] = other
    CArray::JIT.clear_registry
    rebuilt = compile_kernel(source)
    assert(rebuilt.compiled, "a corrupt cache entry should be rebuilt")

    array = CArray.double(3)
    array[0] = 1.0
    rebuilt.call({ :a => array }, {}, [[1, 3, 1]])
    assert_equal(121.0, array[2])
  ensure
    FileUtils.remove_entry(other) if other && File.directory?(other)
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

  def test_cache_directory_is_created_private
    nested = File.join(@directory, "created")
    ENV["CARRAY_JIT_CACHE"] = nested
    compile_indexed(5)
    assert_equal(0700, File.stat(CArray::JIT.cache_directory).mode & 0777)
  end

end
