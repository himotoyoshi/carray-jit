require_relative "test_helper"

# `a, b = b, a`
#
# Ruby settles every value on the right before it writes any of them, and the
# compiler does the same by making each value a statement of its own first.
# So the tests here are mostly one question asked several ways: does the right
# read what was there before the left was written?
#
# The spelling is `jit_for`'s own business as much as a convenience.  A
# recurrence advances by a parallel assignment in Ruby, and until this it had
# to be unpicked by hand into a temporary -- which is the line a reader gets
# wrong.
class TestParallelAssignment < Minitest::Test

  # ---------- what it means ----------

  def test_two_locals_swap
    x = CArray.double(4).seq!
    y = CArray.double(4).seq!(10.0)
    CArray.jit_for(4) { |i|
      left = x[i]
      right = y[i]
      left, right = right, left
      x[i] = left
      y[i] = right
    }
    assert_equal([10.0, 11.0, 12.0, 13.0], x.to_a)
    assert_equal([0.0, 1.0, 2.0, 3.0], y.to_a)
  end

  # The one the spelling exists for: written out with a temporary by hand it
  # is three lines, and the middle one is where the mistake goes.
  def test_a_recurrence_advances
    out = CArray.int64(10)
    CArray.jit_for(10) { |i|
      a = 0
      b = 1
      i.times { |k| a, b = b, a + b }
      out[i] = a
    }
    assert_equal([0, 1, 1, 2, 3, 5, 8, 13, 21, 34], out.to_a)
  end

  # The same block run as Ruby, which is the test that matters: the block is
  # ordinary Ruby and the answer is the one Ruby gives.
  def test_the_recurrence_agrees_with_ruby
    out = CArray.int64(12)
    CArray.jit_for(12) { |i|
      a = 0
      b = 1
      i.times { |k| a, b = b, a + b }
      out[i] = a
    }
    ruby = (0...12).map { |i|
      a = 0
      b = 1
      i.times { a, b = b, a + b }
      a
    }
    assert_equal(ruby, out.to_a)
  end

  # Cells, not just names: this is the swap a sort is written with.
  def test_two_cells_swap
    values = CArray.int32(6).seq!
    CArray.jit_for(3) { |i| values[i], values[5 - i] = values[5 - i], values[i] }
    assert_equal([5, 4, 3, 2, 1, 0], values.to_a)
  end

  def test_a_name_and_a_cell_together
    values = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      carry = 0.0
      carry, out[i] = values[i], carry + values[i]
      out[i] = out[i] + carry
    }
    assert_equal([2.0, 4.0, 6.0, 8.0], out.to_a)
  end

  # Each value keeps its own type, as it would if it had been written on a
  # line of its own.
  def test_two_types_at_once
    counts = CArray.int64(3)
    parts = CArray.double(3)
    CArray.jit_for(3) { |i| counts[i], parts[i] = i * 2, i / 4.0 }
    assert_equal([0, 2, 4], counts.to_a)
    assert_equal([0.0, 0.25, 0.5], parts.to_a)
  end

  def test_three_at_once
    out = CArray.int64(3, 3)
    CArray.jit_for(3) { |i|
      a, b, c = 1, 2, 3
      a, b, c = c, a, b
      out[i, 0] = a
      out[i, 1] = b
      out[i, 2] = c
    }
    assert_equal([[3, 1, 2]] * 3, out.to_a)
  end

  # Each statement gets names of its own for its values.  Shared, they would
  # be one C variable live at the head of the inner loop below -- a variable
  # the loop carries -- and the Integers before it and the Floats inside it
  # were refused for changing the type of `value1` on the way round: a name
  # the author never wrote, about a value dead by the end of its own line.
  def test_two_of_them_at_different_types
    ints = CArray.int64(3)
    reals = CArray.double(3)
    CArray.jit_for(3) { |i|
      a = 1
      b = 2
      a, b = b, a + b
      x = 1.5
      y = 2.5
      3.times { |k| x, y = y, x + y }
      ints[i] = a * 10 + b
      reals[i] = x + y
    }
    assert_equal([23, 23, 23], ints.to_a)
    assert_equal([17.0, 17.0, 17.0], reals.to_a)
  end

  # `if` and `while` make no scope, so the names are the same variables
  # inside them -- and the value carries the branch's mask the way any other
  # assignment standing there does.
  def test_inside_a_branch_and_a_while
    values = CArray.double(6).seq!
    out = CArray.double(6)
    CArray.jit_for(6) { |i|
      a = values[i]
      b = 0.0
      if a > 2.0
        a, b = b, a
      end
      n = 0
      while n < 2
        a, b = b + 1.0, a
        n = n + 1
      end
      out[i] = a * 10.0 + b
    }
    ruby = (0...6).map { |i|
      a = i.to_f
      b = 0.0
      if a > 2.0 then a, b = b, a end
      n = 0
      while n < 2
        a, b = b + 1.0, a
        n = n + 1
      end
      a * 10.0 + b
    }
    assert_equal(ruby, out.to_a)
  end

  # ---------- the other spellings ----------

  # In the whole-array spellings a name on the left is the array itself, and
  # the swap is the one CArray's own operators would have made -- each side
  # reads what the other started with.
  def test_whole_arrays_swap
    hi = CArray.double(4).seq!(1.0)
    lo = CArray.double(4).seq!(10.0)
    CArray.jit_each { hi, lo = lo, hi }
    assert_equal([10.0, 11.0, 12.0, 13.0], hi.to_a)
    assert_equal([1.0, 2.0, 3.0, 4.0], lo.to_a)
  end

  def test_in_a_compiled_function
    difference = CArray.jit_function("double difference(double a, double b)") { |a, b|
      x = a
      y = b
      10.times { |k| x, y = y, x - y }
      x + y
    }
    ruby = lambda { |a, b|
      x = a
      y = b
      10.times { x, y = y, x - y }
      x + y
    }
    assert_equal(ruby.call(5.0, 3.0), difference.call(5.0, 3.0))
  end

  def test_in_jit_init
    out = CArray.int64(4)
    out.jit_init { |i|
      a = i
      b = i * 2
      a, b = b, a
      a
    }
    assert_equal([0, 2, 4, 6], out.to_a)
  end

  # ---------- the order, seen in the C ----------

  # Every value first, then every write.  Without that the swap below would
  # write the first name and read it back as the second.
  def test_the_values_are_settled_before_anything_is_written
    x = CArray.double(4).seq!
    kernel = CArray.jit_for(4) { |i|
      left = x[i]
      right = x[i] * 2.0
      left, right = right, left
      x[i] = left + right
    }
    source = kernel.c_source
    # `value1 = right; value2 = left; left = value1; right = value2;` -- the
    # second value is settled before the first name is written, which is the
    # whole of what the spelling promises.
    last_value = source.index("value2 = ")
    first_write = source.index("left = value1;")
    assert(last_value && first_write,
           "expected the values and the writes in the C source")
    assert(last_value < first_write,
           "every value is settled before anything is written, and was not")
  end

  # ---------- masks ----------

  # A local carries a mask beside its value, and a value on the right is a
  # local like any other -- so a missing cell reaches the left.
  def test_a_missing_cell_travels_through
    values = CArray.double(5).seq!
    values[2] = UNDEF
    out = CArray.double(5)
    CArray.jit_for(5) { |i|
      left = values[i]
      right = values[i] * 2.0
      left, right = right, left
      out[i] = left + right
    }
    assert_equal(1, out.count_masked)
    assert(out.is_masked[2])
    assert_equal([0.0, 3.0, 9.0, 12.0],
                 out.to_a.values_at(0, 1, 3, 4))
  end

  # ---------- what it refuses ----------

  def refusal (&block)
    assert_raises(CArray::JIT::Unsupported) { block.call }
  end

  def test_a_splat_on_the_left_is_refused
    out = CArray.int64(4)
    error = refusal { CArray.jit_for(4) { |i| first, *rest = 1, 2, 3; out[i] = first } }
    assert_match(/writes a splat/, error.message)
    assert_match(/how many there are/, error.message)
  end

  def test_a_nested_target_is_refused
    out = CArray.int64(4)
    error = refusal { CArray.jit_for(4) { |i| first, (a, b) = 1, 2; out[i] = first } }
    assert_match(/writes a nested target/, error.message)
    assert_match(/write the names out flat/, error.message)
  end

  # Ruby takes one value apart across the names.  Nothing in a kernel is a
  # value that can be taken apart, so this is told apart from `a, b = b, a`
  # rather than read as it.
  def test_one_value_on_the_right_is_refused
    out = CArray.int64(4)
    error = refusal { CArray.jit_for(4) { |i| a, b = out[i]; out[i] = a } }
    assert_match(/one value per name/, error.message)
    assert_match(/nothing here to take apart/, error.message)
  end

  def test_an_explicit_array_on_the_right_is_refused
    out = CArray.int64(4)
    error = refusal { CArray.jit_for(4) { |i| a, b = [1, 2]; out[i] = a } }
    assert_match(/one value per name/, error.message)
  end

  def test_a_splat_on_the_right_is_refused
    out = CArray.int64(4)
    error = refusal { CArray.jit_for(4) { |i| a, b = 1, *[2]; out[i] = a } }
    assert_match(/`\*` spreads a value/, error.message)
  end

  # Ruby has an answer for either way round, and says so in the refusal.
  def test_too_few_values_is_refused
    out = CArray.int64(4)
    error = refusal { CArray.jit_for(4) { |i| a, b, c = 1, 2; out[i] = a } }
    assert_match(/writes 3 names and has 2 values/, error.message)
    assert_match(/leaves the rest of the names nil/, error.message)
  end

  def test_too_many_values_is_refused
    out = CArray.int64(4)
    error = refusal { CArray.jit_for(4) { |i| a, b = 1, 2, 3; out[i] = a } }
    assert_match(/writes 2 names and has 3 values/, error.message)
    assert_match(/drops the values it has no name for/, error.message)
  end

  # A statement, and a supported one; what it has not got is a value.
  def test_in_value_position_it_is_refused
    values = CArray.double(4).seq!
    error = refusal {
      CArray.jit_map {
        x = values
        y = values * 2.0
        x, y = y, x
      }
    }
    assert_match(/this one is a parallel assignment/, error.message)
    assert_match(/a cell holds a number/, error.message)
    refute_match(/MultiWrite/, error.message)
  end

end
