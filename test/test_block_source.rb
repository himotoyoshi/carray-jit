require_relative "test_helper"

# The block is passed as a block, so its source has to be recovered.
class TestBlockSource < Minitest::Test

  def test_do_end_block
    values = CArray.double(10)
    values[0] = 2.0
    CArray.jit_for(1...10) do |i|
      values[i] = values[i-1] * 1.5
    end
    assert_in_delta(2.0 * 1.5 ** 9, values[9], 1e-9)
  end

  # Two blocks on one line are what defeats Proc#source_location on its own;
  # the instruction sequence reports columns, which tells them apart.
  def test_two_blocks_on_one_line
    first = CArray.double(6); first[0] = 1.0
    second = CArray.double(6); second[0] = 1.0
    CArray.jit_for(1...6) { |i| first[i] = first[i-1] * 2.0 }; CArray.jit_for(1...6) { |i| second[i] = second[i-1] * 3.0 }
    assert_equal(32.0, first[5])
    assert_equal(243.0, second[5])
  end

  def test_block_written_in_a_method
    assert_equal([1.0, 2.0, 4.0, 8.0], run_in_a_method(2.0).to_a)
  end

  def run_in_a_method (weight)
    values = CArray.double(4)
    values[0] = 1.0
    CArray.jit_for(1...4) { |i| values[i] = values[i-1] * weight }
    values
  end

  def test_eval_defined_block_needs_kept_script_lines
    previous = RubyVM.keep_script_lines
    RubyVM.keep_script_lines = true
    values = CArray.double(6)
    values[0] = 1.0
    block = eval("proc { |i| values[i] = values[i-1] * 4.0 }")
    CArray.jit_for(1...6, &block)
    assert_equal(1024.0, values[5])
  ensure
    RubyVM.keep_script_lines = previous
  end

  def test_a_block_is_required
    error = assert_raises(CArray::JIT::Unsupported) { CArray.jit_for(0...4) }
    assert_match(/needs a block/, error.message)
  end

  def test_a_name_the_block_cannot_see_is_reported
    block = proc { |i| nowhere[i] = 1.0 }
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(0...4, &block)
    end
    assert_match(/`nowhere` is not defined/, error.message)
  end

end
