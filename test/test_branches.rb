require_relative "test_helper"

# `if` in statement position, and the UNDEF idiom that goes with it.
#
# Because this compiles CArray kernels rather than Ruby in general, `a[i] ==
# UNDEF` can be given a meaning directly: it is a question about the mask, and
# it is spelled exactly as Ruby spells it.  That also brings the reference
# back -- a masked kernel written this way can be checked against the same
# loop written in Ruby, which a kernel relying on implicit propagation cannot.
class TestBranches < Minitest::Test

  def test_replacing_missing_values_matches_the_ruby_loop
    source = CArray.double(5).seq!
    source[2] = UNDEF
    result = CArray.double(5)
    CArray.jit_for(5) { |i|
      if source[i] == UNDEF
        result[i] = 0.0
      else
        result[i] = Math.sqrt(source[i])
      end
    }

    expected = CArray.double(5)
    (0...5).each { |i|
      expected[i] = (source[i] == UNDEF) ? 0.0 : Math.sqrt(source[i]) }
    assert_equal(expected.to_a, result.to_a)
    refute(result.is_masked.to_a.any?, "the missing cell was filled in, not carried")
  end

  def test_marking_a_cell_missing
    values = CArray.double(6).seq!(-2)
    result = CArray.double(6)
    CArray.jit_for(6) { |i|
      if values[i] < 0.0
        result[i] = UNDEF
      else
        result[i] = Math.sqrt(values[i])
      end
    }

    expected = CArray.double(6)
    (0...6).each { |i|
      values[i] < 0.0 ? (expected[i] = UNDEF) : (expected[i] = Math.sqrt(values[i])) }
    assert_equal(expected.to_a, result.to_a)
  end

  # A branch not taken writes nothing, so the cell keeps what it had -- the
  # same as the modifier `if` would do in Ruby.
  def test_a_branch_without_an_else
    values = CArray.double(5).seq!
    result = CArray.double(5).seq!(100)
    CArray.jit_for(5) { |i| result[i] = UNDEF if values[i] > 2.0 }
    assert_equal([100.0, 101.0, 102.0, UNDEF, UNDEF], result.to_a)
  end

  def test_negated_mask_test
    values = CArray.double(5).seq!
    values[1] = UNDEF
    present = CArray.int64(5)
    CArray.jit_for(5) { |i|
      if values[i] != UNDEF
        present[i] = 1
      else
        present[i] = 0
      end
    }
    assert_equal([1, 0, 1, 1, 1], present.to_a)
  end

  def test_elsif
    values = CArray.double(5).seq!(-2)
    result = CArray.double(5)
    CArray.jit_for(5) { |i|
      if values[i] < 0.0
        result[i] = -1.0
      elsif values[i] == 0.0
        result[i] = 0.0
      else
        result[i] = 1.0
      end
    }
    assert_equal([-1.0, -1.0, 0.0, 1.0, 1.0], result.to_a)
  end

  # Asking about the mask is not reading the value, so it does not carry the
  # mask into what the branch writes.  Reading the value does.
  def test_a_mask_test_does_not_propagate_but_a_value_test_does
    values = CArray.double(4).seq!
    values[1] = UNDEF

    filled = CArray.double(4)
    CArray.jit_for(4) { |i|
      if values[i] == UNDEF
        filled[i] = -1.0
      else
        filled[i] = values[i]
      end
    }
    refute(filled.is_masked.to_a.any?, "a mask test carries no mask")

    guarded = CArray.double(4)
    CArray.jit_for(4) { |i| guarded[i] = 1.0 if values[i] > 0.0 }
    assert(guarded.is_masked[1], "a branch decided on garbage is masked")
  end

  def test_a_statement_if_works_without_any_mask
    values = CArray.double(5).seq!(-2)
    result = CArray.double(5)
    CArray.jit_for(5) { |i|
      if values[i] < 0.0
        result[i] = 0.0
      else
        result[i] = values[i] * 2.0
      end
    }
    assert_equal([0.0, 0.0, 0.0, 2.0, 4.0], result.to_a)
    refute(result.has_mask?, "no mask was needed, so none was made")
  end

  def test_branches_in_the_whole_array_form
    source = CArray.double(5).seq!
    source[3] = UNDEF
    result = CArray.double(5)
    CArray.jit_each {
      if source[] == UNDEF
        result = -1.0
      else
        result = source[] * 2.0
      end
    }
    assert_equal([0.0, 2.0, 4.0, -1.0, 8.0], result.to_a)
  end

  def test_undef_elsewhere_is_refused
    values = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| values[i] = values[i] + UNDEF }
    end
    assert_match(/UNDEF is not a number/, error.message)
  end

  def test_comparing_something_other_than_a_cell_with_undef
    values = CArray.double(3)
    weight = 1.0
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i| values[i] = 1.0 if weight == UNDEF }
    end
    assert_match(/only a cell can be compared with UNDEF/, error.message)
  end

  # Mentioning UNDEF makes it a masked kernel whatever the arrays carry.
  def test_undef_forces_a_masked_kernel
    values = CArray.double(4).seq!
    result = CArray.double(4)
    kernel = CArray.jit_for(4) { |i| result[i] = UNDEF if values[i] > 2.0 }
    assert(kernel.masked)
    assert(result.has_mask?)
  end

  def test_the_mask_is_read_not_the_value
    kernel = compile_kernel("->(i) { a[i] = 0.0 if a[i] == UNDEF }")
    assert_match(/if \( m_a\[/, kernel.c_source)
  end

  # `next` and `break` mean in the compiled loop what they mean in the Ruby
  # loop it replaces, so both are checked against that loop.

  def test_break_leaves_an_inner_loop
    source = CArray.double(3, 6) { |i, j| (j - i - 1).to_f }
    first = CArray.int32(3)
    CArray.jit_for(3) { |i|
      found = -1
      (0...6).each { |j|
        if source[i, j] > 0.5
          found = j
          break
        end
      }
      first[i] = found
    }
    expected = (0...3).map { |i| (0...6).find { |j| source[i, j] > 0.5 } || -1 }
    assert_equal(expected, first.to_a)
  end

  def test_next_skips_the_rest_of_an_inner_iteration
    grid = CArray.double(3, 5) { |i, j| (i + j).even? ? (i + j).to_f : -1.0 }
    total = CArray.double(3)
    CArray.jit_for(3) { |i|
      accumulator = 0.0
      (0...5).each { |j|
        next if grid[i, j] < 0.0
        accumulator = accumulator + grid[i, j]
      }
      total[i] = accumulator
    }
    expected = (0...3).map { |i|
      (0...5).select { |j| grid[i, j] >= 0.0 }.sum { |j| grid[i, j] } }
    assert_equal(expected, total.to_a)
  end

  # In the kernel block `next` skips the cell, which is what it does in the
  # interpreted loop too: the block returns and the loop moves on.
  def test_next_skips_the_cell
    source = CArray.double(6).seq!(1.0)
    result = CArray.double(6).seq!(100.0)
    CArray.jit_for(6) { |i|
      next if source[i] > 4.0
      result[i] = source[i] * 10.0
    }
    assert_equal([10.0, 20.0, 30.0, 40.0, 104.0, 105.0], result.to_a)
  end

  def test_a_skipped_cell_keeps_its_value_and_its_mask
    source = CArray.double(6).seq!(1.0)
    source[2] = UNDEF
    result = CArray.double(6).seq!(100.0)
    CArray.jit_for(6) { |i|
      next if source[i] == UNDEF
      result[i] = source[i] * 2.0
    }
    assert_equal(102.0, result[2], "the cell was not written")
    assert_equal(0, result.count_masked, "and was not marked missing either")
  end

  # What was read before the break still counts, mask and all.
  def test_a_value_read_before_a_break_carries_its_mask
    grid = CArray.double(2, 4).seq!(1.0)
    grid[0, 2] = UNDEF
    total = CArray.double(2)
    CArray.jit_for(2) { |i|
      accumulator = 0.0
      (0...4).each { |j|
        accumulator = accumulator + grid[i, j]
        if grid[i, j] > 2.5
          break
        end
      }
      total[i] = accumulator
    }
    assert(total.is_masked[0])
    assert_equal(5.0, total[1])
  end

  # Ruby's `break` in a block is not a loop exit but a return from the method
  # it was passed to, with a value -- which this cannot produce.
  def test_break_in_the_kernel_block_is_refused
    values = CArray.double(6).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(6) { |i| break if values[i] > 2.0 }
    end
    assert_match(/returns from `jit_for` in Ruby/, error.message)
    assert_match(/`next` skips the cell here/, error.message)
  end

  def test_a_loop_jump_carrying_a_value_is_refused
    values = CArray.double(6).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(6) { |i| (0...3).each { |j| values[i] = 1.0; break 1 } }
    end
    assert_match(/`break` here takes no value/, error.message)

    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(6) { |i| (0...3).each { |j| values[i] = 1.0; next 1 } }
    end
    assert_match(/`next` here takes no value/, error.message)
  end

  # `each` with a `break` is what a `while` would have been, with the bound in
  # the extent -- so the kernel still cannot fail to stop, and a cell that did
  # not converge can be told apart from one that did.
  def test_an_iteration_that_stops_on_a_condition
    values = CArray.double(6) { |i| 1.0 + i * 7.0 }
    root = CArray.double(6)
    passes = CArray.int32(6)
    cap = 50
    tolerance = 1.0e-14

    CArray.jit_for(6) { |i|
      x = values[i]
      taken = 0
      (0...cap).each { |k|
        break if (x * x - values[i]).abs <= tolerance * values[i]
        x = 0.5 * (x + values[i] / x)
        taken = taken + 1
      }
      root[i] = x
      passes[i] = taken
    }

    6.times do |i|
      value = values[i]
      x = value
      taken = 0
      while taken < cap && (x * x - value).abs > tolerance * value
        x = 0.5 * (x + value / x)
        taken += 1
      end
      assert_bits_equal(x, root[i], "cell #{i}")
      assert_equal(taken, passes[i], "cell #{i} took the same number of passes")
    end
    assert(passes.max < cap, "none of them hit the bound")
  end

end
