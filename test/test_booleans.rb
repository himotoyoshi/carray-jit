require_relative "test_helper"

# A boolean CArray is a byte holding 0 or 1, and Ruby reads that byte as
# `true` or `false`.  So a kernel over one has to mean what the Ruby loop
# means at the cell -- where `flags[i]` is a boolean, not a number.
class TestBooleans < Minitest::Test

  # A kernel reaches its arrays as locals the block closed over, so each test
  # makes its own rather than sharing them through instance variables.
  def flags = CArray.boolean(8) { |i| (i % 3).zero? ? 1 : 0 }
  def others = CArray.boolean(8) { |i| i < 4 ? 1 : 0 }
  def numbers = CArray.double(8).seq!(1.0)

  def test_a_boolean_cell_is_a_condition
    flag = flags
    source = numbers
    result = CArray.double(8)
    CArray.jit_for(8) { |i| result[i] = flag[i] ? source[i] : -source[i] }
    assert_equal((0...8).map { |i| flag[i] ? source[i] : -source[i] },
                 result.to_a)
  end

  def test_a_boolean_cell_in_an_if
    flag = flags
    result = CArray.double(8)
    CArray.jit_for(8) { |i|
      if flag[i]
        result[i] = 1.0
      end
    }
    assert_equal((0...8).map { |i| flag[i] ? 1.0 : 0.0 }, result.to_a)
  end

  def test_negation_and_conjunction
    flag = flags
    other = others
    result = CArray.boolean(8)
    CArray.jit_for(8) { |i| result[i] = !flag[i] }
    assert_equal((0...8).map { |i| !flag[i] }, result.to_a)

    CArray.jit_for(8) { |i| result[i] = flag[i] && other[i] }
    assert_equal((0...8).map { |i| flag[i] && other[i] }, result.to_a)
  end

  def test_two_boolean_cells_compare
    flag = flags
    other = others
    result = CArray.boolean(8)
    CArray.jit_for(8) { |i| result[i] = flag[i] == other[i] }
    assert_equal((0...8).map { |i| flag[i] == other[i] }, result.to_a)
  end

  def test_comparing_with_true
    flag = flags
    result = CArray.double(8)
    CArray.jit_for(8) { |i| result[i] = flag[i] == true ? 9.0 : 0.0 }
    assert_equal((0...8).map { |i| flag[i] == true ? 9.0 : 0.0 }, result.to_a)
  end

  def test_a_comparison_is_stored_as_a_boolean
    source = numbers
    result = CArray.boolean(8)
    CArray.jit_for(8) { |i| result[i] = source[i] > 4.5 }
    assert_equal((0...8).map { |i| source[i] > 4.5 }, result.to_a)
    assert_equal("boolean", result.data_type_name)
  end

  # CArray takes 1 and 0 for true and false, and nothing else.
  def test_one_and_zero_are_accepted
    result = CArray.boolean(4)
    CArray.jit_for(4) { |i| result[i] = 1 }
    assert_equal([true] * 4, result.to_a)
    CArray.jit_for(4) { |i| result[i] = 0 }
    assert_equal([false] * 4, result.to_a)
  end

  def test_a_number_is_not_stored_into_a_boolean_array
    source = numbers
    result = CArray.boolean(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| result[i] = source[i] }
    end
    assert_match(/holds `true` and `false`/, error.message)
  end

  def test_a_boolean_is_not_stored_into_a_numeric_array
    flag = flags
    result = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| result[i] = flag[i] }
    end
    assert_match(/not a number/, error.message)
  end

  # Ruby answers `flags[i] == 1` rather than raising, and the answer is always
  # false -- so compiling it would be compiling a bug.
  def test_comparing_a_boolean_cell_with_a_number_is_refused
    flag = flags
    result = CArray.double(8)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(8) { |i| result[i] = flag[i] == 1 ? 9.0 : 0.0 }
    end
    assert_match(/is false whatever the cell holds/, error.message)
    assert_match(/Write `if flags\[i\]`/, error.message)
  end

  def test_arithmetic_on_a_boolean_cell_is_refused
    flag = flags
    result = CArray.double(8)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(8) { |i| result[i] = flag[i] + 1.0 }
    end
    assert_match(/cannot combine types boolean and double/, error.message)
  end

  # The array-level `flags + 1` promotes in CArray, and the cell-level
  # `flags[i] + 1` raises in Ruby.  A kernel is the cell loop either way it is
  # written, so both forms take the cell's answer.
  def test_the_whole_array_form_takes_the_cell_rule_too
    flag = flags
    result = CArray.double(8)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { result = flag + 1 }
    end
    assert_match(/cannot combine types boolean/, error.message)
  end

  def test_a_comparison_over_whole_arrays
    source = numbers
    result = CArray.boolean(8)
    CArray.jit_each { result = source > 4.0 }
    assert_equal((source > 4.0).to_a, result.to_a)
  end

  def test_a_boolean_array_carries_a_mask_like_any_other
    flags = CArray.boolean(8) { |i| 1 }
    flags[2] = UNDEF
    result = CArray.double(8)
    CArray.jit_for(8) { |i|
      if flags[i] == UNDEF
        result[i] = -1.0
      else
        result[i] = flags[i] ? 1.0 : 0.0
      end
    }
    assert_equal([1.0, 1.0, -1.0, 1.0, 1.0, 1.0, 1.0, 1.0], result.to_a)
  end

  def test_undef_marks_a_boolean_cell
    flags = CArray.boolean(4)
    CArray.jit_for(4) { |i| flags[i] = UNDEF }
    assert_equal(4, flags.count_masked)
  end

  # The byte stored is 0 or 1, which is CArray's contract for the type; a
  # kernel is not where that stops being true.
  def test_the_stored_byte_is_zero_or_one
    source = numbers
    result = CArray.boolean(6)
    CArray.jit_for(6) { |i| result[i] = source[i] > 2.5 }
    bytes = result.refer(CA_INT8, [6]).to_a
    assert_equal([0, 0, 1, 1, 1, 1], bytes)
  end

end
