require_relative "test_helper"
require "tmpdir"
require "rbconfig"

class TestCache < Minitest::Test

  def setup
    @directory = Dir.mktmpdir("carray-jit-test-")
    @previous = ENV["CARRAY_JIT_CACHE"]
    ENV["CARRAY_JIT_CACHE"] = @directory
    CArray::JIT.clear_registry
  end

  def teardown
    ENV["CARRAY_JIT_CACHE"] = @previous
    FileUtils.remove_entry(@directory)
    CArray::JIT.clear_registry
  end

  def unique_source
    # A fresh constant keeps this run from colliding with a cached object.
    "->(i) { a[i] = a[i-1] * #{rand} }"
  end

  def test_second_compilation_reuses_the_shared_object
    source = unique_source
    first = compile_kernel(source)
    assert(first.compiled, "the first build should invoke the compiler")

    CArray::JIT.clear_registry
    second = compile_kernel(source, arrays: { :a => "float64" })
    refute(second.compiled, "the second build should reuse the cached object")
  end

  def test_registry_returns_the_same_kernel_within_a_process
    source = unique_source
    first = compile_kernel(source, arrays: { :a => "float64" })
    second = compile_kernel(source, arrays: { :a => "float64" })
    assert_same(first, second)
  end

  def test_storage_type_is_part_of_the_key
    source = unique_source
    double_kernel = compile_kernel(source, arrays: { :a => "float64" })
    float_kernel = compile_kernel(source, arrays: { :a => "float32" })
    refute_same(double_kernel, float_kernel)
    assert_includes(double_kernel.c_source, "(double *)")
    assert_includes(float_kernel.c_source, "(float *)")
  end

  def test_capture_types_are_part_of_the_key
    source = "->(i) { a[i] = c * a[i-1] }"
    with_float = compile_kernel(source, scalars: { :c => 2.0 })
    with_integer = compile_kernel(source, arrays: { :a => "float64" }, scalars: { :c => 2 })
    refute_same(with_float, with_integer)
    assert_includes(with_float.c_source, "double c")
    assert_includes(with_integer.c_source, "int64_t c")
  end

  def test_cache_directory_holds_source_alongside_object
    compile_kernel(unique_source, arrays: { :a => "float64" })
    leaf = CArray::JIT.cache_directory
    assert_equal(1, Dir[File.join(leaf, "*.c")].size)
    refute_empty(Dir[File.join(leaf, "*.bundle")] + Dir[File.join(leaf, "*.so")])
  end

  # Kernels from another version or architecture cannot be reused, so they
  # live in their own directory rather than sharing the cache budget.  CArray's
  # version is in the name for a reason of its own: a kernel is handed CArray's
  # memory, on layouts CArray decides, so one compiled against one version and
  # run against the next would answer wrongly rather than fail to load.
  def test_cache_is_split_by_version_and_architecture
    leaf = CArray::JIT.cache_directory
    assert_equal(@directory, CArray::JIT.cache_root)
    assert_equal(File.join(@directory,
                           "#{CArray::JIT::VERSION}-carray#{CArray::VERSION}-" \
                           "#{RbConfig::CONFIG['arch']}"),
                 leaf)
  end

  # The command that looks after the cache loads the compiler and nothing else,
  # so that a cache can be cleared when CArray itself will not load.  It has to
  # arrive at the same directory all the same, which it does by asking RubyGems
  # for the version a `require` would have activated.
  def test_the_carray_version_is_reachable_without_the_extension
    tag = `#{Gem.ruby} #{File.expand_path("../bin/carray-jit", __dir__)}`
    assert_predicate($?, :success?)
    assert_includes(tag, CArray::JIT::Compiler.environment_tag)
  end

  # `-march=native` names a target the flag's own text does not carry, and
  # `arch` is too coarse to stand in for it -- `x86_64-linux` spans machines
  # that differ only in which instructions exist.  So what the compiler
  # actually chose goes into the key.
  def test_a_native_target_is_part_of_the_key
    compiler = CArray::JIT::Compiler
    native = compiler.send(:probe_macros, compiler.compiler_command, ["-march=native"])
    skip "this compiler will not report its predefined macros" unless native

    source = unique_source
    plain = compiler.digest(source, ["-O2"])
    with_native = compiler.digest(source, ["-O2", "-march=native"])
    refute_equal(plain, with_native)

    # And the identity is the target's, not the flag's spelling: a named
    # target that resolves elsewhere keys differently.
    assert_equal("", compiler.send(:target_identity, ["-O2"]),
                 "a flag set with no native target costs nothing to key")
    refute_empty(compiler.send(:target_identity, ["-O2", "-march=native"]))
  end

end
