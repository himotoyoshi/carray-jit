require_relative "test_helper"

# `raise "..."` inside a kernel.
#
# C has no exception to throw and no way to carry a message out of a cell, so
# the message is registered as the kernel is compiled, the cell that raises
# writes its code into the error slot the kernel is already watching for a
# division with no divisor, and the raise happens on the Ruby side once the
# loop has stopped and control is back. What the caller sees is the
# RuntimeError `raise "..."` gives in Ruby.
class TestRaise < Minitest::Test

  def test_it_raises_with_the_message_it_was_given
    a = CArray.int64(6).seq!(1)
    out = CArray.int64(6)
    error = assert_raises(RuntimeError) do
      CArray.jit_for(6) { |i| raise "a is too big" if a[i] > 4; out[i] = a[i] * 2 }
    end
    assert_equal("a is too big", error.message)
  end

  # It stops where it raised: the cell that raised is not written and neither
  # are the ones after it, which is what `raise` means in the Ruby loop this
  # stands for. The cells before it keep what the kernel wrote -- as they do
  # when a division by zero stops one.
  def test_it_stops_the_loop_where_it_raised
    a = CArray.int64(6).seq!(1)
    out = CArray.int64(6).seq!(0, 0)
    assert_raises(RuntimeError) do
      CArray.jit_for(6) { |i| raise "too big" if a[i] > 4; out[i] = a[i] * 2 }
    end
    assert_equal([2, 4, 6, 8, 0, 0], out.to_a)
  end

  def test_it_raises_from_the_whole_array_spelling
    a = CArray.int64(4).seq!(1)
    out = CArray.int64(4)
    error = assert_raises(RuntimeError) do
      CArray.jit_each { raise "not positive" if a == 3; out = a }
    end
    assert_equal("not positive", error.message)
  end

  def test_it_raises_from_an_inner_loop
    a = CArray.int64(4).seq!(1)
    out = CArray.int64(4)
    error = assert_raises(RuntimeError) do
      CArray.jit_for(4) { |i|
        total = 0
        4.times { |j| raise "j reached 3" if j == 3; total = total + a[j] }
        out[i] = total
      }
    end
    assert_equal("j reached 3", error.message)
  end

  # A kernel that never raises is a kernel that pays nothing for the message
  # being there: the condition is the block's own.
  def test_a_condition_that_never_holds_raises_nothing
    a = CArray.int64(4).seq!(1)
    out = CArray.int64(4)
    CArray.jit_for(4) { |i| raise "impossible" if a[i] > 100; out[i] = a[i] }
    assert_equal([1, 2, 3, 4], out.to_a)
  end

  # Which one raised has to survive the round trip, and two messages in one
  # kernel are two codes.
  def test_the_message_says_which_raise_it_was
    a = CArray.int64(4).seq!(1)
    out = CArray.int64(4)
    run = lambda { |limit|
      assert_raises(RuntimeError) do
        CArray.jit_for(4) { |i|
          raise "over one" if a[i] > limit && a[i] == 2
          raise "over two" if a[i] > limit && a[i] == 3
          out[i] = a[i]
        }
      end.message
    }
    assert_equal("over one", run.call(1))
    assert_equal("over two", run.call(2))
  end

  # A cell whose value is missing was not asked about: the bytes under a mask
  # mean nothing, so a condition that only holds there is not a failure. This
  # is the rule the division helper keeps, and the one `if` keeps for what it
  # writes.
  def test_a_missing_cell_does_not_raise
    a = CArray.int64(4).seq!(1)
    a[3] = UNDEF
    out = CArray.int64(4)
    CArray.jit_each { raise "the fourth cell" if a == 4; out = a * 2 }
    assert_equal([2, 4, 6], out[0..2].to_a)
    assert_equal([false, false, false, true], out.is_masked.to_a)
  end

  # ---------- what is refused ----------

  def test_the_class_may_not_be_named
    a = CArray.int64(2).seq!
    out = CArray.int64(2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| raise ArgumentError, "no"; out[i] = a[i] }
    end
    assert_match(/takes the message alone/, error.message)
    assert_match(/RuntimeError/, error.message)
  end

  # The message is registered when the kernel is compiled, so it has to be
  # there to register: a string the block computes is not.
  def test_the_message_is_written_out
    a = CArray.int64(2).seq!
    out = CArray.int64(2)
    text = "computed"
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| raise text; out[i] = a[i] }
    end
    assert_match(/written out rather than built/, error.message)
  end

  def test_it_needs_a_message
    a = CArray.int64(2).seq!
    out = CArray.int64(2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| raise; out[i] = a[i] }
    end
    assert_match(/takes the message/, error.message)
  end

  def test_it_is_a_statement_and_not_a_value
    a = CArray.int64(2).seq!
    out = CArray.int64(2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i| out[i] = a[i] > 0 ? raise("high") : 1 }
    end
    assert_match(/`raise` is a statement here/, error.message)
  end

  # ---------- from a compiled function ----------

  # A `jit_function` body raises as a kernel body does. It reports into the
  # flag it already reports a division by zero into -- its own where it stands
  # alone, the kernel's where it is pasted -- and the message travels with the
  # function, so the same line raises the same thing whichever way the body is
  # reached.
  def root
    CArray.jit_function("double root(double x)") { |x|
      raise "x is negative" if x < 0.0
      Math.sqrt(x)
    }
  end

  def test_a_compiled_function_raises_when_called_from_ruby
    f = root
    assert_in_delta(3.0, f.call(9.0), 0.0)
    error = assert_raises(RuntimeError) { f.call(-1.0) }
    assert_equal("x is negative", error.message)
  end

  def test_a_compiled_function_raises_from_a_kernel
    f = root
    a = CArray.double(4) { |i| i - 1.0 }
    out = CArray.double(4)
    error = assert_raises(RuntimeError) do
      CArray.jit_for(4) { |i| out[i] = f.call(a[i]) }
    end
    assert_equal("x is negative", error.message)
  end

  # Its code comes back through the kernel's slot, so the kernel is what has
  # to know the message -- it takes the pasted body's messages as its own, and
  # the codes agree because they are taken from the messages.
  def test_the_kernel_answers_for_what_it_pasted
    f = root
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    kernel = CArray.jit_for(4) { |i| out[i] = f.call(a[i]) }
    assert_equal([1.0, Math.sqrt(2.0), Math.sqrt(3.0), 2.0], out.to_a)
    assert_equal(f.raise_messages, kernel.raise_messages)
    refute_empty(f.raise_messages)
  end

  # Both can raise in one kernel, and what comes back is the one that was
  # reached.
  def test_the_kernels_own_raise_and_the_functions_stay_apart
    f = root
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    error = assert_raises(RuntimeError) do
      CArray.jit_for(4) { |i| raise "i reached 3" if i == 3; out[i] = f.call(a[i]) }
    end
    assert_equal("i reached 3", error.message)

    b = CArray.double(4) { |i| -i.to_f }
    error = assert_raises(RuntimeError) do
      CArray.jit_for(4) { |i| raise "i reached 3" if i == 3; out[i] = f.call(b[i]) }
    end
    assert_equal("x is negative", error.message)
  end

  # A body that calls itself passes the slot down, so a raise deep in the
  # recursion is the one that comes back.
  def test_a_recursive_function_raises_from_where_it_reached
    walk = CArray.jit_function("long long walk(long long n)") { |n|
      raise "walked past zero" if n < 0
      n == 0 ? 0 : n + walk.call(n - 1)
    }
    assert_equal(6, walk.call(3))
    error = assert_raises(RuntimeError) { walk.call(-1) }
    assert_equal("walked past zero", error.message)
  end
end
