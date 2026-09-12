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

end
