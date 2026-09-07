$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tmpdir"
require "fileutils"

# Keep the suite out of the developer's own cache: it compiles hundreds of
# throwaway kernels that would otherwise pile up in ~/.cache/carray-jit.
#
# One directory that stays, rather than a fresh one per run.  What a kernel
# costs to build here is mostly not the compiler: on macOS the first dlopen of
# a newly written object is checked by the system, which takes around 200 ms
# against 40 ms of compiling, and the result is remembered per object.  Paying
# that once per kernel instead of once per run is the whole difference between
# a suite that takes two minutes and one that takes twenty seconds.
#
# Nothing stale can be reused: the cache key is a digest of the generated C
# and of the toolchain, so a kernel that changed is a different entry.  The
# limit is raised because the suite alone builds some 450 of them, and the
# default would evict entries this run is about to want again.
#
# CARRAY_JIT_TEST_COLD=1 uses a fresh directory and removes it afterwards,
# which is how to exercise the compile path itself rather than the cache.
TEST_CACHE_DIRECTORY =
  if ENV["CARRAY_JIT_TEST_COLD"]
    Dir.mktmpdir("carray-jit-test-")
  else
    File.join(Dir.tmpdir, "carray-jit-test-cache").tap { |path|
      FileUtils.mkdir_p(path)
    }
  end
ENV["CARRAY_JIT_CACHE"] = TEST_CACHE_DIRECTORY
ENV["CARRAY_JIT_CACHE_LIMIT"] ||= "2000"
Minitest.after_run do
  if ENV["CARRAY_JIT_TEST_COLD"] && File.directory?(TEST_CACHE_DIRECTORY)
    FileUtils.remove_entry(TEST_CACHE_DIRECTORY)
  end
end

require "carray/jit"


module KernelCompilation

  # Compiles from source text rather than a block, so a test can pin the
  # generated C or exercise a rejection without a live array.
  def compile_kernel (source, arrays: { :a => "float64" }, scalars: {})
    CArray::JIT.compile(source,
                        array_names: arrays.keys,
                        storage_types: arrays,
                        scalar_values: scalars)
  end

  def refuse (source, pattern, arrays: { :a => "float64" }, scalars: {})
    error = assert_raises(CArray::JIT::Unsupported) do
      compile_kernel(source, arrays: arrays, scalars: scalars)
    end
    assert_match(pattern, error.message)
    error
  end

end

module KernelAssertions

  # Float comparisons here are deliberately exact.  Agreeing with the Ruby
  # evaluator to the last bit is the property under test; a tolerance would
  # hide exactly the bugs this suite exists to catch (FMA contraction,
  # computing in float instead of double).
  # A Complex is two doubles, and both of them are compared the same way --
  # the sign of a zero included, because that is what a branch cut is made
  # of.  A NaN carries no sign anyone promises, though: Ruby's own complex
  # division and C's `__divdc3` part company only over which NaN they leave
  # behind, so every NaN is folded to one bit pattern before the comparison.
  def bits_of (value)
    doubles = value.is_a?(Complex) ? [value.real, value.imaginary] : [value]
    doubles = doubles.map { |d| d.is_a?(Float) && d.nan? ? Float::NAN : d }
    doubles.pack("d#{doubles.size}")
  end

  def assert_bits_equal (expected, actual, message = nil)
    expected_bits = bits_of(expected)
    actual_bits = bits_of(actual)
    assert_equal(expected_bits.unpack1("H*"), actual_bits.unpack1("H*"),
                 message || "expected #{expected} (bitwise), got #{actual}")
  end

  def assert_arrays_bits_equal (expected, actual)
    assert_equal(expected.elements, actual.elements, "lengths differ")
    expected.elements.times do |index|
      assert_bits_equal(expected[index], actual[index], "cell #{index} differs")
    end
  end

end

class Minitest::Test
  include KernelAssertions
  include KernelCompilation
end
