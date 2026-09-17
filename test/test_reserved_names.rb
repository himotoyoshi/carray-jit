require_relative "test_helper"

# Names the generated C already uses, reached by a block that closed over
# something called one of them.
#
# `CGenerator::RESERVED_NAMES` is the kernel's own parameters -- scanned out
# of the signature, so it cannot fall behind it -- and C's keywords.  An index
# named from that list is refused, because its name is written in the block
# and read back in messages.  A capture's name is not: it belongs to the
# surrounding program, and what the C calls it is nobody's business, so it is
# moved out of the way instead.
#
# What these pin is that the moving happens at all, that only a name that had
# to move moves, and that the value still arrives.  The hazard is not a
# strange one to hit: `data` is a kernel parameter and an ordinary thing to
# call a variable.
class TestReservedNames < Minitest::Test

  # A captured scalar under each of the kernel's own parameter names.  These
  # compiled to C that redeclared the parameter, or to a `double double`.
  def test_a_captured_scalar_named_after_a_kernel_parameter
    values = CArray.double(4).seq!
    out = CArray.double(4)
    data = 2.0
    error = 3.0
    strides = 5.0
    bounds = 7.0
    reals = 11.0
    integers = 13.0
    pointers = 17.0
    functions = 19.0
    CArray.jit_for(4) { |i|
      out[i] = values[i] + data + error + strides + bounds + reals +
               integers + pointers + functions
    }
    expected = 2.0 + 3.0 + 5.0 + 7.0 + 11.0 + 13.0 + 17.0 + 19.0
    4.times { |i| assert_bits_equal(i + expected, out[i]) }
  end

  def test_a_captured_scalar_named_after_a_c_keyword
    values = CArray.double(4).seq!
    out = CArray.double(4)
    int = 2.0
    double = 3.0
    register = 5.0
    restrict = 7.0
    CArray.jit_for(4) { |i|
      out[i] = values[i] + int + double + register + restrict
    }
    4.times { |i| assert_bits_equal(i + 17.0, out[i]) }
  end

  # An array handed to a C function whole is declared under its own name in
  # the kernel's body, which is where `double *const double` came from.
  def test_an_addressed_array_named_after_a_c_keyword
    sum = CArray.jit_function("double sum(const double c[4])") { |c|
      c[0] + c[1] + c[2] + c[3]
    }
    double = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i| out[i] = sum.call(double) }
    4.times { |i| assert_bits_equal(10.0, out[i]) }
  end

  def test_an_addressed_array_named_after_a_kernel_parameter
    sum = CArray.jit_function("double sum(const double c[4])") { |c|
      c[0] + c[1] + c[2] + c[3]
    }
    data = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i| out[i] = sum.call(data) }
    4.times { |i| assert_bits_equal(10.0, out[i]) }
  end

  # A borrowed function arrives as an address held in a local of the kernel's
  # body, under the name the block reached it by.
  def test_a_borrowed_function_named_after_a_c_keyword
    double = CArray.jit_extern("double j0(double)")
    values = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i| out[i] = double.call(values[i]) }
    4.times { |i| assert_bits_equal(double.call(i + 1.0), out[i]) }
  end

  # Two captures that differ only in whether they had to move still differ.
  def test_a_moved_name_does_not_land_on_another
    values = CArray.double(4).seq!
    out = CArray.double(4)
    data = 2.0
    carray_jit_name_data = 100.0
    CArray.jit_for(4) { |i| out[i] = values[i] + data * carray_jit_name_data }
    4.times { |i| assert_bits_equal(i + 200.0, out[i]) }
  end

  # Only a name that had to move moves.  The generated C is the debugging
  # surface, so a block that named nothing awkwardly reads as it always did.
  def test_an_ordinary_name_is_left_alone
    values = CArray.double(4).seq!
    out = CArray.double(4)
    data = 2.0
    scale = 3.0
    kernel = CArray.jit_for(4) { |i| out[i] = values[i] * scale + data }
    assert_includes(kernel.c_source, "const double scale = reals[")
    assert_includes(kernel.c_source, "const double carray_jit_name_data = reals[")
    refute_match(/const double data =/, kernel.c_source)
  end

  # An index keeps the refusal it had: its name is the block's own text.
  def test_an_index_is_still_refused
    values = CArray.double(4).seq!
    out = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |data| out[data] = values[data] }
    end
    assert_match(/is a name the kernel's own C uses/, error.message)
    assert_match(/cannot be an index/, error.message)
  end

  # ---------- locals ----------

  # A local under the names the generator gives a captured array.  `a_n0`
  # hid the extent a computed index is checked against, and the check
  # compared with 1.
  def test_a_local_named_after_an_arrays_decorations
    a = CArray.double(5).seq!(1.0)
    position = CArray.int64(5) { [4, 0, 3, 1, 2] }
    out = CArray.double(5)
    CArray.jit_for(5) { |i|
      a_n0 = 1
      p_a = 2.0
      a_s0 = 3
      m_a = 4.0
      out[i] = a[position[i]] * p_a + a_n0 + a_s0 + m_a
    }
    reference = (0...5).map { |i|
      a_n0 = 1
      p_a = 2.0
      a_s0 = 3
      m_a = 4.0
      a[position[i]] * p_a + a_n0 + a_s0 + m_a
    }
    assert_arrays_bits_equal(CArray.double(5) { reference }, out)
  end

  def test_a_local_named_after_a_kernel_parameter_in_a_kernel_that_reports
    divisor = CArray.int64(4).seq!(1)
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      error = 1.0
      data = 2.0
      bounds = 3.0
      strides = 4.0
      out[i] = 10 / divisor[i] + error + data + bounds + strides
    }
    reference = (0...4).map { |i|
      error = 1.0
      data = 2.0
      bounds = 3.0
      strides = 4.0
      10 / divisor[i] + error + data + bounds + strides
    }
    assert_arrays_bits_equal(CArray.double(4) { reference }, out)
  end

  # `for` is a word Ruby keeps too, so no block can name a local that.
  def test_a_local_named_after_a_c_keyword
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      int = 1
      double = 2.0
      out[i] = a[i] * double + int
    }
    reference = (0...4).map { |i|
      int = 1
      double = 2.0
      a[i] * double + int
    }
    assert_arrays_bits_equal(CArray.double(4) { reference }, out)
  end

  def test_a_local_named_after_a_temporary_in_a_masked_kernel
    m = CArray.double(4).seq!(1.0)
    m[1] = UNDEF
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      masked1 = m[i] * 2.0
      masked__1 = m[i] + 1.0
      out[i] = masked1 + masked__1
    }
    assert_equal([false, true, false, false], out.is_masked.to_a)
    reference = [0, 2, 3].map { |i|
      masked1 = m[i] * 2.0
      masked__1 = m[i] + 1.0
      masked1 + masked__1
    }
    assert_equal(reference.pack("d*"), [out[0], out[2], out[3]].pack("d*"))
  end

  # The block's own `x__2` and the variable `x` gets when it changes type
  # were one C variable.
  def test_a_local_spelled_like_a_retyped_one
    a = CArray.double(3).seq!(1.0)
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      x = 1
      y = x * 3
      x = 1.5
      x__2 = 10.0
      out[i] = x + x__2 + y + a[i]
    }
    reference = (0...3).map { |i|
      x = 1
      y = x * 3
      x = 1.5
      x__2 = 10.0
      x + x__2 + y + a[i]
    }
    assert_arrays_bits_equal(CArray.double(3) { reference }, out)
  end

  def test_a_split_accumulator_named_after_a_kernel_parameter
    b = CArray.double(16).seq!(1.0)
    out = CArray.double(2)
    kernel = CArray.jit_for(2) { |i|
      error = 0.0
      (0...16).each { |k| error += b[k] * (i + 1) }
      out[i] = error
    }
    assert_includes(kernel.c_source, "carray_jit_name1_error__p0")
    reference = (0...2).map { |i|
      error = 0.0
      (0...16).each { |k| error += b[k] * (i + 1) }
      error
    }
    assert_arrays_bits_equal(CArray.double(2) { reference }, out)
  end

  # A function's C has the flag a pasted body is handed as a parameter, and
  # C's keywords like anything else.
  def test_a_local_in_a_function_named_after_its_flag_or_a_keyword
    f = CArray.jit_function("int64_t f(int64_t n)") { |n|
      carray_jit_error = 3
      int = 4
      10 / n + carray_jit_error + int
    }
    reference = ->(n) { carray_jit_error = 3; int = 4; 10 / n + carray_jit_error + int }
    assert_equal(reference.(2), f.call(2))

    values = CArray.int64(3).seq!(1)
    out = CArray.int64(3)
    CArray.jit_each { out = f.call(values) }
    assert_equal([1, 2, 3].map { |n| reference.(n) }, out.to_a)
  end

  # ---------- a local spelled like another's binding ----------

  # `acc` at its second type and the block's own `acc__2` are two locals.
  # A fold is recognised by its accumulator appearing in the term, and the
  # one appearing here is the other local, so the loop is not a fold.
  def test_a_loop_reading_a_local_spelled_like_the_accumulators_binding
    b = CArray.double(16).seq!(1.0)
    out = CArray.double(2)
    kernel = CArray.jit_for(2) { |i|
      acc = 0
      acc = 0.5
      acc__2 = 100.0
      (0...16).each { |k| acc = acc__2 + b[k] * (i + 1) }
      out[i] = acc
    }
    reference = (0...2).map { |i|
      acc = 0
      acc = 0.5
      acc__2 = 100.0
      (0...16).each { |k| acc = acc__2 + b[k] * (i + 1) }
      acc
    }
    assert_arrays_bits_equal(CArray.double(2) { reference }, out)
    refute_match(/__p0/, kernel.c_source, "the loop is not split as a fold")
  end

  def test_the_same_loop_inside_a_while
    b = CArray.double(16).seq!(1.0)
    out = CArray.double(2)
    kernel = CArray.jit_for(2) { |i|
      acc = 0
      acc = 0.5
      acc__2 = 100.0
      c = 0
      while c < 2
        (0...16).each { |k| acc = acc__2 + b[k] * (i + c + 1) }
        c += 1
      end
      out[i] = acc
    }
    reference = (0...2).map { |i|
      acc = 0
      acc = 0.5
      acc__2 = 100.0
      c = 0
      while c < 2
        (0...16).each { |k| acc = acc__2 + b[k] * (i + c + 1) }
        c += 1
      end
      acc
    }
    assert_arrays_bits_equal(CArray.double(2) { reference }, out)
    refute_match(/__p0/, kernel.c_source, "the loop is not split as a fold")
  end

  def test_the_same_loop_in_one_arm_of_an_if
    b = CArray.double(16).seq!(1.0)
    out = CArray.double(3)
    kernel = CArray.jit_for(3) { |i|
      acc = 0
      acc = 0.5
      acc__2 = 100.0
      if i != 1
        (0...16).each { |k| acc = acc__2 + b[k] * (i + 1) }
      end
      out[i] = acc
    }
    reference = (0...3).map { |i|
      acc = 0
      acc = 0.5
      acc__2 = 100.0
      if i != 1
        (0...16).each { |k| acc = acc__2 + b[k] * (i + 1) }
      end
      acc
    }
    assert_arrays_bits_equal(CArray.double(3) { reference }, out)
    refute_match(/__p0/, kernel.c_source, "the loop is not split as a fold")
  end

  def test_the_same_loop_in_a_masked_kernel
    b = CArray.double(16).seq!(1.0)
    b[3] = UNDEF
    out = CArray.double(2)
    kernel = CArray.jit_for(2) { |i|
      acc = 0
      acc = 0.5
      acc__2 = 100.0
      (0...16).each { |k| acc = acc__2 + b[k] * (i + 1) }
      out[i] = acc
    }
    # The value and the mask a cell leaves are the last pass's, and the last
    # pass reads a cell that is there.
    cells = b.to_a.each_with_index.map { |v, k| b.is_masked[k] ? nil : v }
    reference = (0...2).map { |i|
      acc = 0
      acc = 0.5
      missing = false
      acc__2 = 100.0
      (0...16).each { |k|
        acc = acc__2 + (cells[k] || 0.0) * (i + 1)
        missing = cells[k].nil?
      }
      [acc, missing]
    }
    assert_equal(reference.map(&:last), out.is_masked.to_a)
    assert_arrays_bits_equal(CArray.double(2) { reference.map(&:first) }, out)
    refute_match(/__p0/, kernel.c_source, "the loop is not split as a fold")
  end

  # ---------- two moved locals ----------

  # `error` at its second type and the block's own `error__2` are both moved,
  # and a moved name with a suffix on it may not land on another moved name.
  def test_a_moved_local_with_a_suffix_and_a_moved_local_spelled_that_way
    a = CArray.double(3).seq!(1.0)
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      error = 1
      y = error * 3
      error = 1.5
      error__2 = 10.0
      out[i] = error + error__2 + y + a[i]
    }
    reference = (0...3).map { |i|
      error = 1
      y = error * 3
      error = 1.5
      error__2 = 10.0
      error + error__2 + y + a[i]
    }
    assert_arrays_bits_equal(CArray.double(3) { reference }, out)
  end

  def test_the_same_with_a_split_accumulator
    b = CArray.double(16).seq!(1.0)
    out = CArray.double(2)
    kernel = CArray.jit_for(2) { |i|
      error = 1
      y = error * 3
      error = 0.5
      error__2 = 10.0
      (0...16).each { |k| error += b[k] * (i + 1) }
      out[i] = error + error__2 + y
    }
    reference = (0...2).map { |i|
      error = 1
      y = error * 3
      error = 0.5
      error__2 = 10.0
      (0...16).each { |k| error += b[k] * (i + 1) }
      error + error__2 + y
    }
    assert_includes(kernel.c_source, "carray_jit_name1_error__2__p0")
    assert_arrays_bits_equal(CArray.double(2) { reference }, out)
  end

  def test_the_same_in_a_masked_kernel
    m = CArray.double(3).seq!(1.0)
    m[1] = UNDEF
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      error = 1
      y = error * 3
      error = 1.5
      error__2 = m[i] * 10.0
      out[i] = error + error__2 + y
    }
    assert_equal([false, true, false], out.is_masked.to_a)
    reference = [0, 2].map { |i|
      error = 1
      y = error * 3
      error = 1.5
      error__2 = m[i] * 10.0
      error + error__2 + y
    }
    assert_equal(reference.pack("d*"), [out[0], out[2]].pack("d*"))
  end

  # A leading underscore right after the number: `_x__2` is moved, `_x` is
  # not, and `_x` at its second type is written `_x__2`.
  def test_a_moved_local_that_starts_with_an_underscore
    a = CArray.double(3).seq!(1.0)
    out = CArray.double(3)
    kernel = CArray.jit_for(3) { |i|
      _x = 1
      y = _x * 3
      _x = 1.5
      _x__2 = 10.0
      out[i] = _x + _x__2 + y + a[i]
    }
    reference = (0...3).map { |i|
      _x = 1
      y = _x * 3
      _x = 1.5
      _x__2 = 10.0
      _x + _x__2 + y + a[i]
    }
    assert_includes(kernel.c_source, "carray_jit_name1__x__2")
    assert_arrays_bits_equal(CArray.double(3) { reference }, out)
  end

  def test_an_index_named_after_a_decoration_or_a_suffix_is_refused
    a = CArray.double(4).seq!
    out = CArray.double(4)
    [proc { CArray.jit_for(4) { |p_a| out[p_a] = a[p_a] } },
     proc { CArray.jit_for(4) { |k__2| out[k__2] = a[k__2] } }].each do |run|
      error = assert_raises(CArray::JIT::Unsupported) { run.call }
      assert_match(/is a name the kernel's own C uses/, error.message)
    end
  end

end
