require_relative "test_helper"

# printf inside a kernel, for looking at what it is doing.  The format is
# rewritten on the way to C, since the same directive does not mean the same
# thing in both languages: Ruby's `%d` takes any Integer and C's takes an
# `int`, which is not what a cell holds.
class TestPrintf < Minitest::Test

  def printed
    out, = capture_subprocess_io { yield }
    out
  end

  def test_it_prints_from_an_indexed_kernel
    values = CArray.double(3).seq!
    result = CArray.double(3)
    text = printed do
      CArray.jit_for(3) { |i| printf("i=%d a=%g\n", i, values[i]); result[i] = values[i] * 2 }
    end
    assert_equal("i=0 a=0\ni=1 a=1\ni=2 a=2\n", text)
    assert_equal([0.0, 2.0, 4.0], result.to_a)
  end

  def test_it_prints_from_an_element_kernel
    values = CArray.double(2).seq!
    text = printed do
      assert_equal([0.0, 2.0], CArray.jit_map { printf("x=%g\n", values); values * 2 }.to_a)
    end
    assert_equal("x=0\nx=1\n", text)
  end

  # Flags, width and precision are the writer's, and `%%` is a per cent sign.
  def test_it_keeps_the_shape_of_the_conversion
    values = CArray.double(2) { |i| i + 0.5 }
    result = CArray.double(2)
    text = printed do
      CArray.jit_for(2) { |i| printf("[%5.2f] [%03d] 100%%\n", values[i], i); result[i] = values[i] }
    end
    assert_equal("[ 0.50] [000] 100%\n[ 1.50] [001] 100%\n", text)
  end

  # C has no directive for a complex, so it is printed as the two numbers it
  # is, with the sign of the imaginary part always shown.
  def test_it_prints_a_complex_as_two_numbers
    values = CArray.cmplx128(2) { |i| Complex(i, -1) }
    result = CArray.cmplx128(2)
    text = printed do
      CArray.jit_for(2) { |i| printf("z=%g\n", values[i]); result[i] = values[i] }
    end
    assert_equal("z=0-1i\nz=1-1i\n", text)
  end

  def test_it_prints_a_comparison
    values = CArray.double(3).seq!
    result = CArray.double(3)
    text = printed do
      CArray.jit_for(3) { |i| printf("%d\n", values[i] > 1); result[i] = values[i] }
    end
    assert_equal("0\n0\n1\n", text)
  end

  def test_a_real_is_not_printed_as_an_integer
    values = CArray.double(3).seq!
    result = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| printf("%d\n", values[i]); result[i] = values[i] }
    end
    assert_match(/is a real.*write `%g`/, error.message)
  end

  def test_an_integer_is_not_printed_as_a_real
    values = CArray.double(3).seq!
    result = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| printf("%g\n", i); result[i] = values[i] }
    end
    assert_match(/is an integer.*write `%d`/, error.message)
  end

  def test_the_count_has_to_agree
    values = CArray.double(3).seq!
    result = CArray.double(3)
    short = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| printf("%d %d\n", i); result[i] = values[i] }
    end
    assert_match(/more values than were given/, short.message)

    long = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| printf("%d\n", i, i); result[i] = values[i] }
    end
    assert_match(/more values than its format asks for/, long.message)
  end

  # C reads the format at compile time, so it cannot be worked out at run time.
  def test_the_format_has_to_be_written_out
    values = CArray.double(3).seq!
    result = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| printf(1, i); result[i] = values[i] }
    end
    assert_match(/format has to be written out/, error.message)
  end

end
