require_relative "test_helper"

# A reduction is a per-cell computation like any other: the caller says where
# the answer goes, and the kernel fills that cell.
#
#   out[i] = <the reduction for the i-th cell>
#
# What makes it expressible is an inner loop, `(from...to).each { |j| ... }`,
# whose index addresses arrays but writes nothing.  The accumulator is then an
# ordinary block-local, which is why sum, max, product, count and a dot
# product all fall out without a primitive each.
class TestReductions < Minitest::Test

  def matrix (rows = 3, columns = 4)
    CArray.double(rows, columns).seq!(1)
  end

  def test_row_sums
    source = matrix
    rows, columns = source.dim
    total = CArray.double(rows)
    CArray.jit_for(rows) { |i|
      accumulator = 0.0
      (0...columns).each { |j| accumulator = accumulator + source[i, j] }
      total[i] = accumulator
    }

    expected = (0...rows).map { |i| (0...columns).sum { |j| source[i, j] } }
    rows.times { |i| assert_bits_equal(expected[i], total[i], "row #{i}") }
  end

  def test_row_maxima
    source = matrix
    rows, columns = source.dim
    peak = CArray.double(rows)
    CArray.jit_for(rows) { |i|
      best = source[i, 0]
      (1...columns).each { |j| best = source[i, j] if source[i, j] > best }
      peak[i] = best
    }
    assert_equal([4.0, 8.0, 12.0], peak.to_a)
  end

  def test_column_sums
    source = matrix
    rows, columns = source.dim
    total = CArray.double(columns)
    CArray.jit_for(columns) { |j|
      accumulator = 0.0
      (0...rows).each { |i| accumulator = accumulator + source[i, j] }
      total[j] = accumulator
    }
    expected = (0...columns).map { |j| (0...rows).sum { |i| source[i, j] } }
    assert_equal(expected, total.to_a)
  end

  # Two outer indices and one inner one.  Neither the kernel iterator nor a
  # broadcast expression reaches this shape.
  def test_matrix_multiply
    rows, inner, columns = 3, 4, 2
    left = CArray.double(rows, inner).seq!(1)
    right = CArray.double(inner, columns).seq!(1)
    result = CArray.double(rows, columns)

    CArray.jit_for(rows, columns) { |i, j|
      accumulator = 0.0
      (0...inner).each { |t| accumulator = accumulator + left[i, t] * right[t, j] }
      result[i, j] = accumulator
    }

    expected = (0...rows).map { |i|
      (0...columns).map { |j| (0...inner).sum { |t| left[i, t] * right[t, j] } }
    }
    assert_equal(expected, result.to_a)
  end

  # A whole-array reduction is the same thing with a one-cell box.
  # Subscripts bind indices to axes by name, which is how Einstein notation
  # is written: which index walks which axis, and which ones are summed over.
  # Inner loops nest, so a contraction over several indices is several loops.
  def test_a_double_contraction
    ni, nk, nl, nj = 3, 4, 3, 2
    left = CArray.double(ni, nk, nl).seq!(1)
    right = CArray.double(nl, nk, nj).seq!(1)
    result = CArray.double(ni, nj)

    CArray.jit_for(ni, nj) { |i, j|
      accumulator = 0.0
      (0...nk).each { |k|
        (0...nl).each { |l| accumulator = accumulator + left[i, k, l] * right[l, k, j] }
      }
      result[i, j] = accumulator
    }

    expected = (0...ni).map { |i|
      (0...nj).map { |j|
        (0...nk).sum { |k| (0...nl).sum { |l| left[i, k, l] * right[l, k, j] } }
      }
    }
    assert_equal(expected, result.to_a)
  end

  # One index may walk two axes of the same array, which is a trace.
  def test_a_trace
    rows, size = 3, 4
    source = CArray.double(rows, size, size).seq!(1)
    trace = CArray.double(rows)
    CArray.jit_for(rows) { |i|
      accumulator = 0.0
      (0...size).each { |j| accumulator = accumulator + source[i, j, j] }
      trace[i] = accumulator
    }
    assert_equal((0...rows).map { |i| (0...size).sum { |j| source[i, j, j] } },
                 trace.to_a)
  end

  def test_a_full_contraction_into_a_one_cell_box
    rows, columns = 3, 4
    left = CArray.double(rows, columns).seq!(1)
    right = CArray.double(rows, columns).seq!(2)
    box = CArray.double(1)
    CArray.jit_for(1) { |z|
      accumulator = 0.0
      (0...rows).each { |i|
        (0...columns).each { |j| accumulator = accumulator + left[i, j] * right[i, j] }
      }
      box[z] = accumulator
    }
    assert_equal((0...rows).sum { |i| (0...columns).sum { |j| left[i, j] * right[i, j] } },
                 box[0])
  end

  # The outer indices need not address the axes in their own order.
  def test_a_transposing_read
    source = CArray.double(3, 4).seq!(1)
    result = CArray.double(4, 3)
    CArray.jit_for(4, 3) { |i, j| result[i, j] = source[j, i] }
    assert_equal(source.transpose.to_a, result.to_a)
  end

  def test_whole_array_sum_into_a_one_cell_box
    values = CArray.double(10).seq!(1)
    length = values.elements
    box = CArray.double(1)
    CArray.jit_for(1) { |i|
      accumulator = 0.0
      (0...length).each { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    assert_equal(55.0, box[0])
  end

  def test_count_and_product
    values = CArray.double(3, 4).seq!(1)
    rows, columns = values.dim
    counted = CArray.int64(rows)
    product = CArray.double(rows)
    CArray.jit_for(rows) { |i|
      seen = 0
      running = 1.0
      (0...columns).each { |j|
        seen = seen + 1 if values[i, j] > 2.0
        running = running * values[i, j]
      }
      counted[i] = seen
      product[i] = running
    }
    assert_equal((0...rows).map { |i| (0...columns).count { |j| values[i, j] > 2.0 } },
                 counted.to_a)
    assert_equal((0...rows).map { |i| (0...columns).inject(1.0) { |a, j| a * values[i, j] } },
                 product.to_a)
  end

  def test_an_inclusive_inner_range
    values = CArray.double(5).seq!(1)
    box = CArray.double(1)
    CArray.jit_for(1) { |i|
      accumulator = 0.0
      (0..4).each { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    assert_equal(15.0, box[0])
  end

  def test_the_inner_range_may_be_built_from_captured_scalars
    values = CArray.double(8).seq!(1)
    first = 2
    last = 6
    box = CArray.double(1)
    CArray.jit_for(1) { |i|
      accumulator = 0.0
      (first...last).each { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    assert_equal((2...6).sum { |j| values[j] }, box[0])
  end

  # `n.times` is `(0...n).each` with both ends implied, and compiles to the
  # same loop -- so the count is built from what a range end is built from,
  # and the index is scoped and bounds-checked the same way.
  def test_times_as_an_inner_loop
    values = CArray.double(5).seq!(1)
    box = CArray.double(1)
    CArray.jit_for(1) { |i|
      accumulator = 0.0
      5.times { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    assert_equal(15.0, box[0])
  end

  def test_the_count_of_times_may_be_a_captured_scalar
    values = CArray.double(8).seq!(1)
    count = 6
    box = CArray.double(1)
    CArray.jit_for(1) { |i|
      accumulator = 0.0
      count.times { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    assert_equal((0...6).sum { |j| values[j] }, box[0])
  end

  def test_times_and_the_range_it_stands_for_compile_alike
    values = CArray.double(5).seq!(1)
    box = CArray.double(1)
    counted = CArray.jit_for(1) { |i|
      accumulator = 0.0
      5.times { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    ranged = CArray.jit_for(1) { |i|
      accumulator = 0.0
      (0...5).each { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    # Past the banner, which quotes the source each was written from.
    body = ->(source) { source.sub(/\A\/\*.*?\*\/\n/m, "") }
    assert_equal(body[ranged.c_source], body[counted.c_source])
  end

  # `break` and `next` mean in the generated loop what they mean in the Ruby
  # loop, and `times` is a loop in both languages, so both belong to it.
  def test_break_and_next_inside_times
    values = CArray.double(8).seq!(1)
    box = CArray.double(1)
    CArray.jit_for(1) { |i|
      accumulator = 0.0
      8.times { |j|
        next if values[j] == 2.0
        break if values[j] > 5.0
        accumulator = accumulator + values[j]
      }
      box[i] = accumulator
    }
    assert_equal(1.0 + 3.0 + 4.0 + 5.0, box[0])
  end

  def test_the_index_of_times_is_scoped_to_its_loop
    values = CArray.double(4).seq!(1)
    box = CArray.double(1)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i| 4.times { |j| box[i] = values[j] }; box[i] = values[j] }
    end
    assert_match(/`j`/, error.message)
  end

  def test_times_may_not_reuse_an_index_in_scope
    values = CArray.double(4).seq!(1)
    box = CArray.double(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| 4.times { |i| box[i] = values[i] } }
    end
    assert_match(/`i` is already an index here/, error.message)
  end

  # A fixed subscript pins an axis, and can sit alongside the index that walks
  # it -- a[i, 0] and a[i, j] on the same array is ordinary.
  def test_a_fixed_subscript
    source = matrix
    rows, columns = source.dim
    difference = CArray.double(rows)
    CArray.jit_for(rows) { |i|
      accumulator = 0.0
      (1...columns).each { |j| accumulator = accumulator + (source[i, j] - source[i, 0]) }
      difference[i] = accumulator
    }
    expected = (0...rows).map { |i|
      (1...columns).sum { |j| source[i, j] - source[i, 0] } }
    assert_equal(expected, difference.to_a)
  end

  def test_the_inner_index_is_scoped_to_its_loop
    values = CArray.double(4).seq!
    length = 4
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(1) { |i|
        accumulator = 0.0
        (0...length).each { |j| accumulator = accumulator + values[j] }
        values[i] = values[j]
      }
    end
    assert_match(/`j`/, error.message)
  end

  # An array the kernel writes is written once per outer cell; reading it
  # through an inner index would reach cells another outer iteration owns.
  def test_a_written_array_cannot_be_read_through_an_inner_index
    values = CArray.double(4).seq!
    length = 4
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i|
        accumulator = 0.0
        (0...length).each { |j| accumulator = accumulator + values[j] }
        values[i] = accumulator
      }
    end
    assert_match(/cannot also be read through the inner index/, error.message)
  end

  # An inner loop runs over a range, which is what makes its extent knowable
  # before the kernel runs.
  def test_an_inner_loop_over_something_other_than_a_range
    values = CArray.double(4)
    other = CArray.double(4).seq!
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| other.each { |j| values[i] = 1.0 } }
    end
    assert_match(/an inner loop runs over a range/, error.message)
  end

  def test_masks_accumulate_through_a_reduction
    source = CArray.double(2, 3).seq!(1)
    source[0, 1] = UNDEF
    rows, columns = source.dim
    total = CArray.double(rows)
    CArray.jit_for(rows) { |i|
      accumulator = 0.0
      (0...columns).each { |j| accumulator = accumulator + source[i, j] }
      total[i] = accumulator
    }
    assert(total.is_masked[0], "a missing cell makes its row's sum missing")
    refute(total.is_masked[1])
    assert_equal(4.0 + 5.0 + 6.0, total[1])
  end

  # The same axis at two independent positions.  Written as a reduction this is
  # a Gram matrix; the point is that the two indices address one axis, which
  # the analysis used to keep to one index apiece.
  def test_an_axis_read_at_two_index_positions
    source = CArray.double(5, 3).seq!(1)
    gram = CArray.double(3, 3)
    CArray.jit_for(3, 3) { |a, b|
      accumulator = 0.0
      (0...5).each { |p| accumulator = accumulator + source[p, a] * source[p, b] }
      gram[a, b] = accumulator
    }
    expected = (0...3).map { |a| (0...3).map { |b|
      (0...5).sum { |p| source[p, a] * source[p, b] } } }
    assert_equal(expected, gram.to_a)
  end

  def test_two_index_positions_alongside_a_pinned_one
    source = CArray.double(5, 3).seq!(1)
    result = CArray.double(3, 3)
    CArray.jit_for(3, 3) { |a, b|
      accumulator = 0.0
      (0...5).each { |p|
        accumulator = accumulator + source[p, a] * source[p, b] * source[p, 0]
      }
      result[a, b] = accumulator
    }
    expected = (0...3).map { |a| (0...3).map { |b|
      (0...5).sum { |p| source[p, a] * source[p, b] * source[p, 0] } } }
    assert_equal(expected, result.to_a)
  end

  def test_each_index_is_bounds_checked_on_its_own
    source = CArray.double(5, 3).seq!(1)
    result = CArray.double(3, 3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3, 3) { |a, b|
        accumulator = 0.0
        (0...5).each { |p| accumulator = accumulator + source[p, a] * source[p, b+1] }
        result[a, b] = accumulator
      }
    end
    assert_match(/`source` is indexed at `source\[.*b \+ 1\]`/, error.message)
  end

  # An axis of a written array may be walked by two indices too.  Here the cell
  # read is one the loop also writes, so the answer depends on the order -- and
  # the extent is where the order is written, so the kernel means what the same
  # Ruby loop means, in either direction.
  def self_reference_in_ruby (order)
    values = (0...3).map { |i| (0...3).map { |j| (i * 3 + j).to_f } }
    (0...3).each { |a| order.each { |b| values[a][b] = values[a][a] + 1.0 } }
    values
  end

  def test_a_written_axis_walked_by_two_indices_runs_the_extent_upward
    values = CArray.double(3, 3).seq!
    CArray.jit_for(3, 3) { |a, b| values[a, b] = values[a, a] + 1.0 }
    assert_equal(self_reference_in_ruby((0...3).to_a), values.to_a)
  end

  def test_a_written_axis_walked_by_two_indices_runs_the_extent_downward
    values = CArray.double(3, 3).seq!
    CArray.jit_for(3, 2.step(0, -1)) { |a, b| values[a, b] = values[a, a] + 1.0 }
    assert_equal(self_reference_in_ruby(2.step(0, -1).to_a), values.to_a)
    refute_equal(self_reference_in_ruby((0...3).to_a), values.to_a,
                 "the two orders really do give different answers")
  end

end
