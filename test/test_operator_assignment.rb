require_relative "test_helper"

# `x += e` is `x = x + e`, and is compiled as exactly that -- so what it
# means, what it refuses and what it is allowed to reassociate are the same
# as the assignment it stands for.
class TestOperatorAssignment < Minitest::Test

  def test_a_local_accumulator
    values = CArray.double(8).seq!(1.0)
    out = CArray.double(1)
    CArray.jit_for(1) { |i|
      total = 0.0
      (0...8).each { |j| total += values[j] }
      out[i] = total
    }
    assert_equal([36.0], out.to_a)
  end

  # The accumulator is still a fold, so it is still split into partial sums.
  def test_a_fold_written_with_it_is_still_split
    values = CArray.double(64).seq!(1.0)
    out = CArray.double(1)
    kernel = CArray.jit_for(1) { |i|
      total = 0.0
      (0...64).each { |j| total += values[j] }
      out[i] = total
    }
    assert_equal([(1..64).sum.to_f], out.to_a)
    assert_includes(kernel.c_source, "total__p0")
  end

  def test_a_cell_of_an_array
    values = CArray.double(4) { |i| i + 1.0 }
    out = CArray.double(4) { 10.0 }
    CArray.jit_for(4) { |i| out[i] += values[i] }
    assert_equal([11.0, 12.0, 13.0, 14.0], out.to_a)
  end

  # A row of workspace is the case this reads best in, and the index may be
  # the inner loop's.
  def test_a_row_of_workspace
    rows, width = 3, 4
    work = CArray.double(rows, width) { 1.0 }
    CArray.jit_for(rows) { |i| (0...width).each { |k| work[i, k] += i + k } }
    expected = Array.new(rows) { |i| Array.new(width) { |k| 1.0 + i + k } }
    assert_equal(expected, work.to_a)
  end

  # A histogram: the cell is worked out, which is a scatter, and reading it
  # back to add to it is what the same Ruby loop does.
  def test_a_scatter
    where = CArray.int32(8) { |i| i % 3 }
    counts = CArray.int32(3)
    CArray.jit_for(8) { |i| counts[where[i]] += 1 }
    assert_equal([3, 3, 2], counts.to_a)
  end

  def test_the_other_operators
    values = CArray.int32(4) { |i| i + 1 }
    out = CArray.int32(4)
    CArray.jit_for(4) { |i|
      shifted = values[i]
      shifted <<= 2
      shifted &= 12
      out[i] = shifted
    }
    assert_equal((1..4).map { |v| (v << 2) & 12 }, out.to_a)

    powers = CArray.double(4)
    CArray.jit_for(4) { |i|
      raised = values[i] * 1.0
      raised **= 2
      powers[i] = raised
    }
    assert_equal([1.0, 4.0, 9.0, 16.0], powers.to_a)
  end

  # The whole-array spelling has no index to write, and the name that is an
  # array outside is the array written.
  def test_the_whole_array_spelling
    left = CArray.double(4) { 1.0 }
    right = CArray.double(4) { |i| i + 1.0 }
    CArray.jit_each { left += right }
    assert_equal([2.0, 3.0, 4.0, 5.0], left.to_a)
  end

  def test_a_cscalar
    total = CScalar.double() { 0.0 }
    values = CArray.double(8).seq!(1.0)
    CArray.jit_for(8) { |i| total[] += values[i] }
    assert_equal(36.0, total[0])
  end

  # Through a pointer parameter it is the read and the write it stands for,
  # both of which a compiled function already has.
  def test_a_pointer_parameter
    bump = CArray.jit_function("double bump(double v[], int64_t k)") { |v, k|
      v[k] += 2.0
      v[k]
    }
    scratch = CArray.double(3) { 1.0 }
    assert_equal(3.0, bump.call(scratch, 0))
    assert_equal([3.0, 1.0, 1.0], scratch.to_a)
  end

  # The read is a read like any other, so a missing cell carries into what is
  # written -- which is what `out[i] = out[i] + source[i]` does.
  def test_a_masked_cell
    source = CArray.double(4) { 1.0 }
    source[2] = UNDEF
    out = CArray.double(4) { 0.0 }
    CArray.jit_for(4) { |i| out[i] += source[i] }
    assert_equal(UNDEF, out[2])
    assert_equal([1.0, 1.0, 1.0], [out[0], out[1], out[3]])
  end

  def test_an_index_may_not_be_moved
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| i += 1 ; values[i] = 1.0 }
    end
    assert_match(/`i` is a loop index/, error.message)
  end

  def test_a_local_read_before_it_is_assigned
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| total += 1.0 ; values[i] = total }
    end
    assert_match(/`total` is read before it is assigned/, error.message)
  end

  def test_or_and_and_assignment
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| held = 0.0 ; held ||= 1.0 ; values[i] = held }
    end
    assert_match(/`\|\|=` asks whether the value is already nil or false/, error.message)
  end

  # A refusal names what was written rather than the node it was read as.
  def test_a_refused_statement_is_named_as_it_was_written
    values = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| unless i > 0 then values[i] = 1.0 end }
    end
    assert_match(/got `unless` -- write it as `if` with the condition negated/,
                 error.message)
    refute_match(/Prism|Node/, error.message)
  end

end
