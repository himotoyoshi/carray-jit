require_relative "test_helper"

# A constant stands where a local stands.  It matters because `def` closes
# over nothing: inside a method body a constant is the only name that reaches
# a table or a compiled function written outside it.
class TestConstants < Minitest::Test

  TABLE  = CArray.double(3) { |i| i * 2.0 }
  SCALE  = 2.5
  DOUBLE = CArray.jit_function("double twice(double)") { |x| x * 2.0 }

  module Inner
    K = 3.0
    def self.scaled (a)
      CArray.jit_map { a * K }
    end

    TABLE = CArray.double(3) { |i| i * 2.0 }

    # No local reaches in here; TABLE is how the table arrives.
    def self.from_a_method_body
      out = CArray.double(3)
      CArray.jit_for(3) { |i| out[i] = TABLE[i] }
      out
    end
  end

  def test_constant_array_is_indexed
    out = CArray.double(3)
    CArray.jit_for(3) { |i| out[i] = TABLE[i] }
    assert_equal [0.0, 2.0, 4.0], out.to_a
  end

  def test_constant_scalar_is_read
    out = CArray.double(3)
    CArray.jit_for(3) { |i| out[i] = i * SCALE }
    assert_equal [0.0, 2.5, 5.0], out.to_a
  end

  def test_constant_function_is_called
    out = CArray.double(3)
    CArray.jit_for(3) { |i| out[i] = DOUBLE.call(i * 1.0) }
    assert_equal [0.0, 2.0, 4.0], out.to_a
  end

  def test_constant_reaches_into_a_method_body
    assert_equal [0.0, 2.0, 4.0], Inner.from_a_method_body.to_a
  end

  def test_constant_in_an_element_kernel
    a = CArray.double(3) { |i| i }
    assert_equal [0.0, 2.5, 5.0], CArray.jit_map { a * SCALE }.to_a
    assert_equal [0.0, 2.0, 4.0], CArray.jit_map { TABLE * 1.0 }.to_a
  end

  # A constant means what it means where the block was written.
  def test_constant_is_read_in_its_own_scope
    a = CArray.double(3) { |i| i }
    assert_equal [0.0, 3.0, 6.0], Inner.scaled(a).to_a
  end

  # A qualified name is one name too.  It is spelled with underscores in the
  # C, since `::` means nothing there, but that is the generator's business.
  def test_a_qualified_constant_stands_where_a_plain_one_does
    out = CArray.double(3)
    CArray.jit_for(3) { |i| out[i] = TestConstants::TABLE[i] }
    assert_equal [0.0, 2.0, 4.0], out.to_a

    CArray.jit_for(3) { |i| out[i] = i * TestConstants::SCALE }
    assert_equal [0.0, 2.5, 5.0], out.to_a

    CArray.jit_for(3) { |i| out[i] = TestConstants::DOUBLE.call(i * 1.0) }
    assert_equal [0.0, 2.0, 4.0], out.to_a
  end

  # Math is answered by the analyzer itself, in either spelling.
  def test_a_math_constant_is_not_captured
    a = CArray.double(3) { |i| i }
    assert_in_delta 6.283185307179586, CArray.jit_map { a * Math::PI }.to_a[2], 1e-12
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_map { a * Math::TAU }
    end
    assert_match(/unsupported constant Math::TAU/, error.message)
  end

  def test_undefined_constant_says_so
    a = CArray.double(3) { |i| i }
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_map { a * NO_SUCH_CONSTANT }
    end
    assert_match(/NO_SUCH_CONSTANT/, error.message)
  end

  # UNDEF is a mark, not a value, and keeps saying so.
  def test_undef_is_not_captured
    a = CArray.double(3) { |i| i }
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_map { a + UNDEF }
    end
    assert_match(/not a number/, error.message)
  end

end
