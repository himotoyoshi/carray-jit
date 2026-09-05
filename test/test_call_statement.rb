require_relative "test_helper"

# A call standing where a statement stands, its value dropped.
#
# Every other thing this compiler writes is a computation, and a computation
# nobody takes the value of is a line that does nothing -- so it stays
# refused.  A C function is the exception: a parameter of its own can carry an
# address, so what it did may be somewhere other than in the value it
# returned, and dropping that value is what C does with such a call every day.
class TestCallStatement < Minitest::Test

  # A function that reaches its work through a pointer, which is the whole
  # reason a call would want to stand alone.
  def writer_function
    @writer_function ||= CArray.jit_function(
      "int writer(double out[], int64_t at, double value)"
    ) { |out, at, value|
      out[at] = value
      0
    }
  end

  def test_a_call_may_stand_alone_in_a_kernel
    writer = writer_function
    target = CArray.double(6).fill(-1.0)
    CArray.jit_for(6) { |i| writer.call(target, i, i * 10.0) }
    assert_equal([0.0, 10.0, 20.0, 30.0, 40.0, 50.0], target.to_a)
  end

  # The value is dropped, as Ruby drops it, so the block and the kernel are
  # still the same program.
  def test_the_block_does_what_the_kernel_does
    writer = writer_function
    target = CArray.double(4).fill(-1.0)
    CArray.jit_for(4) { |i| writer.call(target, i, i + 0.5) }
    in_ruby = CArray.double(4).fill(-1.0)
    (0...4).each { |i| writer.block.call(in_ruby, i, i + 0.5) }
    assert_equal(in_ruby.to_a, target.to_a)
  end

  # The generated C says the dropping was meant.
  def test_the_dropped_value_is_cast_away
    writer = writer_function
    target = CArray.double(3)
    kernel = CArray.jit_for(3) { |i| writer.call(target, i, 1.0) }
    assert_match(/\(void\) carray_jit_writer_[0-9a-f]+\(target, i, 1\.0\);/,
                 kernel.c_source)
  end

  # A kernel whose only work is a call has not put its work nowhere: it is
  # wherever the address it handed over pointed.  Before this, "the kernel
  # writes to no array" refused it.
  def test_a_kernel_that_only_calls_is_not_refused
    writer = writer_function
    target = CArray.double(3).fill(9.0)
    CArray.jit_for(3) { |i| writer.call(target, i, 0.0) }
    assert_equal([0.0, 0.0, 0.0], target.to_a)
  end

  # Nothing in this kernel reaches a cell of an array, so there is no stride
  # to be contiguous about, and the dispatcher would have been an `if` with
  # nothing in it.
  def test_a_kernel_reaching_no_cell_has_one_loop
    writer = writer_function
    target = CArray.double(3)
    kernel = CArray.jit_for(3) { |i| writer.call(target, i, 2.0) }
    refute_match(/carray_jit_strided\(pointers/, kernel.c_source.split("carray_jit_kernel").last)
  end

  # A function calls itself the same way, which is what a recursion that walks
  # an array wants: quicksort's two halves are called for what they do.
  def test_a_recursive_call_may_stand_alone
    quicksort = CArray.jit_function(
      "int quicksort(double v[], int64_t low, int64_t high)"
    ) { |v, low, high|
      if low < high
        pivot = v[high]
        smaller = low - 1
        scan = low
        while scan < high
          if v[scan] <= pivot
            smaller = smaller + 1
            held = v[smaller]
            v[smaller] = v[scan]
            v[scan] = held
          end
          scan = scan + 1
        end
        held = v[smaller+1]
        v[smaller+1] = v[high]
        v[high] = held
        quicksort.call(v, low, smaller)
        quicksort.call(v, smaller + 2, high)
      end
      0
    }
    values = CArray.double(64) { |i| ((i * 37) % 64) * 1.0 }
    quicksort.call(values, 0, 63)
    assert_equal((0...64).map { |i| i * 1.0 }, values.to_a)
  end

  # `void` is a return type a call may have and a cell may not, so the
  # question only has an answer where the value is dropped -- which is here.
  def test_a_void_extern_may_be_called_for_what_it_does
    ignore = CArray.jit_extern("void srand(unsigned int)")
    seeds = CArray.int32(3).seq!(1)
    CArray.jit_for(3) { |i| ignore.call(seeds[i]) }
  end

  def test_a_void_body_written_here_may_be_called_the_same_way
    fill = CArray.jit_function(
      "void fill(double out[], int64_t at, double value)"
    ) { |out, at, value|
      out[at] = value
    }
    target = CArray.double(5)
    CArray.jit_for(5) { |i| fill.call(target, i, i * 1.5) }
    assert_equal([0.0, 1.5, 3.0, 4.5, 6.0], target.to_a)

    in_ruby = CArray.double(5)
    (0...5).each { |i| fill.block.call(in_ruby, i, i * 1.5) }
    assert_equal(target.to_a, in_ruby.to_a)
  end

  # Its own name is in scope inside a void body too, and the call it makes is
  # a statement for the same reason every other one is.
  def test_a_void_body_may_call_itself
    countdown = CArray.jit_function(
      "void countdown(double out[], int64_t n)"
    ) { |out, n|
      if n > 0
        out[n] = n * 1.0
        countdown.call(out, n - 1)
      end
    }
    run = CArray.double(6)
    countdown.call(run, 5)
    assert_equal([0.0, 1.0, 2.0, 3.0, 4.0, 5.0], run.to_a)
  end

  # A void body reports a failure the way any other does -- through the flag
  # in its own object standing alone, and through the kernel's slot pasted --
  # and where it leaves early it simply returns.
  def test_a_void_body_reports_a_failure
    risky = CArray.jit_function(
      "void risky(int64_t out[], int64_t a, int64_t b)"
    ) { |out, a, b|
      out[0] = a / b
    }
    box = CArray.int64(1)
    risky.call(box, 7, 2)
    assert_equal(3, box[0])
    assert_raises(ZeroDivisionError) { risky.call(box, 7, 0) }

    guard = CArray.jit_function("void guard(double out[], double x)") { |out, x|
      raise "negative" if x < 0.0
      out[0] = Math.sqrt(x)
    }
    error = assert_raises(RuntimeError) { guard.call(CArray.double(1), -1.0) }
    assert_equal("negative", error.message)
    refute_match(/return 0;/, guard.c_source)
  end

  # ---------- what a call does not get to do ----------

  # A cell whose arguments are missing is a cell the function is not told
  # about.  Every other statement can run on bytes that mean nothing and mark
  # what it wrote; a call cannot be taken back, so this follows `raise`.
  def test_a_masked_cell_does_not_reach_the_function
    writer = writer_function
    source = CArray.double(6).seq!(1.0)
    source[2] = UNDEF
    target = CArray.double(6).fill(-1.0)
    CArray.jit_for(6) { |i| writer.call(target, i, source[i] * 10.0) }
    assert_equal([10.0, 20.0, -1.0, 40.0, 50.0, 60.0], target.to_a)
  end

  def test_the_mask_is_read_rather_than_the_value
    writer = writer_function
    source = CArray.double(3).seq!(1.0)
    source[1] = UNDEF
    target = CArray.double(3)
    kernel = CArray.jit_for(3) { |i| writer.call(target, i, source[i]) }
    assert_match(/if \( ! m_source\[/, kernel.c_source)
  end

  # A computation standing alone is still a line that does nothing, and still
  # says so.
  def test_a_computation_may_not_stand_alone
    values = CArray.double(3).seq!(1.0)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| Math.sqrt(values[i]) }
    end
    assert_match(/a kernel body holds assignments/, error.message)
  end

  def test_a_computation_may_not_stand_alone_over_whole_arrays
    a = CArray.double(3).seq!(1.0)
    b = CArray.double(3).seq!(2.0)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { a + b; out = a }
    end
    assert_match(/puts it nowhere/, error.message)
  end
end
