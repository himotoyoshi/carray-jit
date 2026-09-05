require_relative "test_helper"

# Compilation, parsing and code generation must all happen once.  Everything
# on this path costs tens of microseconds, against a few to call the compiled
# kernel, so a repeat call that redid any of it would spend most of its time
# outside the kernel.
class TestFastPath < Minitest::Test

  def setup
    CArray::JIT.clear_registry
  end

  def teardown
    CArray::JIT.clear_registry
  end

  def counting (owner, name)
    original = owner.method(name)
    count = 0
    owner.define_singleton_method(name) do |*arguments, **options, &block|
      count += 1
      original.call(*arguments, **options, &block)
    end
    yield
    count
  ensure
    owner.singleton_class.send(:remove_method, name)
    owner.define_singleton_method(name, original)
  end

  def test_kernel_is_compiled_once_for_a_block
    values = CArray.double(8)
    calls = counting(CArray::JIT::Compiler, :build) do
      5.times { CArray.jit_for(1...8) { |i| values[i] = values[i-1] + 1.0 } }
    end
    assert_equal(1, calls, "the compiler ran more than once")
  end

  # Recovering a block's source parses the whole file it lives in, which is
  # the single most expensive step; the instruction sequence identifies the
  # block so it happens once.
  def test_block_source_is_read_once
    values = CArray.double(8)
    calls = counting(CArray::JIT::BlockReader, :read) do
      5.times { CArray.jit_for(1...8) { |i| values[i] = values[i-1] + 2.0 } }
    end
    assert_equal(1, calls, "the block source was read more than once")
  end

  def test_analysis_happens_once_per_kernel
    values = CArray.double(8)
    calls = counting(CArray::JIT::Analyzer, :new) do
      5.times { CArray.jit_for(1...8) { |i| values[i] = values[i-1] + 3.0 } }
    end
    assert_operator(calls, :<=, 1, "the kernel was analyzed on a repeat call")
  end

  def test_type_assignment_happens_once_per_kernel
    values = CArray.double(8)
    calls = counting(CArray::JIT::TypeAssignment, :new) do
      5.times { CArray.jit_for(1...8) { |i| values[i] = values[i-1] + 4.0 } }
    end
    assert_equal(1, calls, "types were assigned on a repeat call")
  end

  def test_repeat_call_reuses_the_same_kernel_object
    source = "->(i) { a[i] = a[i-1] * 1.5 }"
    assert_same(compile_kernel(source), compile_kernel(source))
  end

  # A capture whose value changes must not recompile, since only its type is
  # part of the kernel.
  def test_changing_a_capture_value_does_not_recompile
    values = CArray.double(8)
    calls = counting(CArray::JIT::Compiler, :build) do
      [0.5, 0.25, 0.125].each do |weight|
        CArray.jit_for(1...8) { |i| values[i] = weight * values[i-1] }
      end
    end
    assert_equal(1, calls)
  end

  # Changing its class does, because the C signature changes with it.
  def test_changing_a_capture_type_compiles_again
    source = "->(i) { a[i] = c * a[i-1] }"
    calls = counting(CArray::JIT::Compiler, :build) do
      compile_kernel(source, scalars: { :c => 2.0 })
      compile_kernel(source, scalars: { :c => 2 })
    end
    assert_equal(2, calls)
  end

  # Two kernels that differ only in which array they touch still share a
  # compiled object, because the C is the same.
  def test_the_same_source_over_different_arrays_compiles_once
    first = CArray.double(8)
    second = CArray.double(8)
    calls = counting(CArray::JIT::Compiler, :build) do
      CArray.jit_for(1...8) { |i| first[i] = first[i-1] + 1.0 }
      CArray.jit_for(1...8) { |i| second[i] = second[i-1] + 1.0 }
    end
    assert_equal(2, calls,
                 "the array's name is part of the generated C, so this is two kernels")
  end

  def test_capture_values_are_reread_each_call
    weight = 2.0
    values = CArray.double(4)
    kernel = proc { |i| values[i] = values[i-1] * weight }

    values[0] = 1.0
    CArray.jit_for(1...4, &kernel)
    assert_equal(8.0, values[3])

    weight = 3.0
    values[0] = 1.0
    CArray.jit_for(1...4, &kernel)
    assert_equal(27.0, values[3])
  end

end
