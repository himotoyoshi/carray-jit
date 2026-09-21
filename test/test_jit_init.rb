require_relative "test_helper"

# jit_init is the constructor block compiled: one parameter per axis, the
# block's value is the cell, and the array written is the receiver.  Every
# case here is checked against the same block run the slow way, because
# "the same answer as `CArray.int32(n, n) { |i, j| ... }`" is the whole
# contract.
class TestJitInit < Minitest::Test

  def test_matches_the_constructor_block
    got = CArray.int32(6, 6).jit_init { |i, j| (i + j) % 2 }
    want = CArray.int32(6, 6) { |i, j| (i + j) % 2 }
    assert_equal want.to_a, got.to_a
  end

  def test_one_axis
    assert_equal [0, 1, 4, 9, 16], CArray.int32(5).jit_init { |i| i * i }.to_a
  end

  def test_three_axes
    got = CArray.int32(2, 3, 4).jit_init { |i, j, k| i * 12 + j * 4 + k }
    assert_equal CArray.int32(2, 3, 4).seq!.to_a, got.to_a
  end

  def test_float_cells
    assert_equal [0.0, 0.5, 1.0, 1.5],
                 CArray.float64(4).jit_init { |i| i / 2.0 }.to_a
  end

  # The receiver is what comes back, as `map_index!` gives its receiver --
  # not a copy of it, and not the kernel.
  def test_returns_the_receiver_itself
    array = CArray.int32(3)
    assert_same array, array.jit_init { |i| i }
  end

  def test_writes_over_what_was_there
    array = CArray.int32(4).seq!(100)
    assert_equal [0, 1, 2, 3], array.jit_init { |i| i }.to_a
  end

  # The reason to have it: a formula the whole-array arithmetic will not say.
  def test_a_branch_per_cell
    got = CArray.int32(6).jit_init { |i| i % 2 == 0 ? i : -i }
    assert_equal [0, -1, 2, -3, 4, -5], got.to_a
  end

  def test_reaches_an_array_it_closes_over
    table = CA_INT([10, 20, 30])
    assert_equal [20, 40, 60], CArray.int32(3).jit_init { |i| table[i] * 2 }.to_a
  end

  def test_reaches_a_scalar_it_closes_over
    k = 7
    assert_equal [7, 8, 9], CArray.int32(3).jit_init { |i| i + k }.to_a
  end

  def test_an_inner_loop_in_the_body
    got = CArray.int32(5).jit_init { |i| s = 0; (0...3).each { |k| s = s + i * k }; s }
    assert_equal [0, 3, 6, 9, 12], got.to_a
  end

  # Integer division floors and the modulo takes the divisor's sign in Ruby,
  # and the compiled loop has to agree: a cell computed in C that differs
  # from the same cell computed in Ruby would make the method unusable as the
  # constructor block's replacement.
  def test_integer_division_and_modulo_follow_ruby
    quotient = CArray.int32(5, 5).jit_init { |i, j| (i - j) / 2 }
    assert_equal CArray.int32(5, 5) { |i, j| (i - j) / 2 }.to_a, quotient.to_a

    remainder = CArray.int32(5, 5).jit_init { |i, j| (i - j) % 3 }
    assert_equal CArray.int32(5, 5) { |i, j| (i - j) % 3 }.to_a, remainder.to_a
  end

  # The receiver decides where the cells go, so a view is filled through
  # itself and the rest of its parent is left alone.
  def test_a_view_as_the_receiver
    base = CArray.int32(5, 5)
    base[1..3, 1..3].jit_init { |i, j| i + j }

    assert_equal [0, 0, 0, 0, 0], base[0, nil].to_a
    assert_equal [0, 1, 2, 3, 0], base[2, nil].to_a
  end

  def test_needs_a_block
    error = assert_raises(CArray::JIT::Unsupported) { CArray.int32(3).jit_init }
    assert_includes error.message, "needs a block"
  end

  # A block naming no index is element-wise, which is another method.
  def test_a_block_that_names_no_index
    error = assert_raises(CArray::JIT::Unsupported) {
      CArray.int32(3).jit_init { 1 }
    }
    assert_includes error.message, "jit_each"
  end

  def test_one_index_per_axis
    error = assert_raises(CArray::JIT::Unsupported) {
      CArray.int32(3, 3).jit_init { |i| i }
    }
    assert_includes error.message, "2 axes"
  end

  # It compiles or it raises.  Falling back to the slow loop would answer a
  # question nobody asked.
  # A splat makes Proc#arity negative, and the count in the message above a
  # number nobody wrote: "the block names -1 indices".
  def test_a_block_that_names_no_count_says_so
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.int32(3).jit_init { |*i| i[0] }
    end
    assert_match(/required parameters/, error.message)
    refute_match(/-1/, error.message)
  end

  def test_a_body_outside_the_subset_raises
    table = { 0 => 1 }
    assert_raises(CArray::JIT::Unsupported) {
      CArray.int32(3).jit_init { |i| table.fetch(i, 0) }
    }
  end

  # jit_init writes the block's value into the receiver; jit_for writes the
  # arrays the block names and answers with the kernel.  Teaching `run` the
  # first must not have changed the second.
  def test_jit_for_still_answers_with_its_kernel
    array = CArray.int32(3)
    kernel = CArray.jit_for(3) { |i| array[i] = i }

    assert_kind_of CArray::JIT::CompiledKernel, kernel
    assert_equal [0, 1, 2], array.to_a
  end

end
