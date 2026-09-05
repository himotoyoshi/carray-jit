require_relative "test_helper"
require "tmpdir"
require "rbconfig"

# Directories for versions and architectures that are no longer in use.
class TestCacheEnvironments < Minitest::Test

  def setup
    @previous = ENV["CARRAY_JIT_CACHE"]
    @previous_age = ENV["CARRAY_JIT_CACHE_MAX_AGE_DAYS"]
    @root = Dir.mktmpdir("carray-jit-environments-")
    ENV["CARRAY_JIT_CACHE"] = @root
    CArray::JIT.clear_registry
  end

  def teardown
    ENV["CARRAY_JIT_CACHE"] = @previous
    ENV["CARRAY_JIT_CACHE_MAX_AGE_DAYS"] = @previous_age
    FileUtils.remove_entry(@root) if File.directory?(@root)
    CArray::JIT.clear_registry
  end

  def plant (name, age_in_days)
    directory = File.join(@root, name)
    FileUtils.mkdir_p(directory)
    entry = File.join(directory, "0" * 64 + ".bundle")
    FileUtils.touch(entry)
    moment = Time.now - age_in_days * 24 * 60 * 60
    File.utime(moment, moment, entry)
    directory
  end

  def test_other_environments_are_reported
    old = plant("0.0.1-arm64-darwin24", 1)
    assert_includes(CArray::JIT.stale_cache_environments, old)
    refute_includes(CArray::JIT.stale_cache_environments, CArray::JIT.cache_directory)
  end

  def test_unused_environments_are_swept_once_old_enough
    ENV["CARRAY_JIT_CACHE_MAX_AGE_DAYS"] = "30"
    ancient = plant("0.0.1-arm64-darwin24", 60)
    recent = plant("0.0.2-arm64-darwin24", 2)

    compile_kernel("->(i) { a[i] = a[i-1] * 21.0 }", arrays: { :a => "float64" })

    refute(File.directory?(ancient), "an environment unused for months should go")
    assert(File.directory?(recent), "a recently used environment should stay")
  end

  def test_current_environment_is_never_swept
    ENV["CARRAY_JIT_CACHE_MAX_AGE_DAYS"] = "0.0001"
    compile_kernel("->(i) { a[i] = a[i-1] * 22.0 }", arrays: { :a => "float64" })
    CArray::JIT.clear_registry
    compile_kernel("->(i) { a[i] = a[i-1] * 23.0 }", arrays: { :a => "float64" })
    assert(File.directory?(CArray::JIT.cache_directory))
    assert_equal(2, CArray::JIT.cache_entry_count)
  end

  def test_clear_cache_leaves_other_environments_alone
    other = plant("0.0.1-arm64-darwin24", 1)
    compile_kernel("->(i) { a[i] = a[i-1] * 24.0 }", arrays: { :a => "float64" })
    CArray::JIT.clear_cache
    assert_equal(0, CArray::JIT.cache_entry_count)
    assert(File.directory?(other), "clear_cache should not touch other versions")
  end

  def test_clear_cache_everything_removes_them
    other = plant("0.0.1-arm64-darwin24", 1)
    compile_kernel("->(i) { a[i] = a[i-1] * 25.0 }", arrays: { :a => "float64" })
    removed = CArray::JIT.clear_cache(everything: true)
    assert_equal(2, removed)
    refute(File.directory?(other))
    assert_equal(0, CArray::JIT.cache_entry_count)
  end

  def test_pruning_is_per_environment
    ENV["CARRAY_JIT_CACHE_LIMIT"] = "2"
    3.times { |index| plant("0.0.#{index}-arm64-darwin24", 1) }
    4.times do |index|
      compile_kernel("->(i) { a[i] = a[i-1] * #{index}.25 }", arrays: { :a => "float64" })
    end
    assert_operator(CArray::JIT.cache_entry_count, :<=, 2)
    assert_equal(3, CArray::JIT.stale_cache_environments.size,
                 "other environments should not be evicted by this one's limit")
  ensure
    ENV.delete("CARRAY_JIT_CACHE_LIMIT")
  end

end
