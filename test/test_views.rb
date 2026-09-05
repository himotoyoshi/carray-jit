require_relative "test_helper"
require "fiddle"

# A kernel must reach a view without the caller having to copy it first.
# Refusing anything but a contiguous entity would break the composability
# views exist for.
class TestViews < Minitest::Test

  def doubling (values, range)
    CArray.jit_for(range) { |i| values[i] = values[i-1] * 2.0 + 1.0 }
  end

  def expected_run (length)
    values = Array.new(length, 0.0)
    values[0] = 1.0
    (1...length).each { |i| values[i] = values[i-1] * 2.0 + 1.0 }
    values
  end

  def test_contiguous_row_of_a_matrix
    matrix = CArray.double(3, 8)
    row = matrix[1, nil]
    row[0] = 1.0
    doubling(row, 1...8)
    assert_equal(expected_run(8), matrix[1, nil].to_a)
    assert_equal([0.0] * 8, matrix[0, nil].to_a, "the other rows stay untouched")
  end

  # A column is strided: its stride is the row pitch, not the element size.
  # This is the case a contiguous-only kernel would have to copy.
  def test_strided_column_of_a_matrix
    matrix = CArray.double(8, 3)
    column = matrix[nil, 1]
    assert_equal(CArray::JIT::Access::TIER_STRIDE,
                 CArray::JIT::Access.classify(column)[:tier])
    column[0] = 1.0
    doubling(column, 1...8)

    assert_equal(expected_run(8), matrix[nil, 1].to_a)
    assert_equal([0.0] * 8, matrix[nil, 0].to_a)
    assert_equal([0.0] * 8, matrix[nil, 2].to_a)
  end

  def test_reversed_view_has_a_negative_stride
    array = CArray.double(6)
    reversed = array[-1..0]
    assert_equal(CArray::JIT::Access::TIER_STRIDE,
                 CArray::JIT::Access.classify(reversed)[:tier])
    reversed[0] = 1.0
    doubling(reversed, 1...6)
    assert_equal(expected_run(6).reverse, array.to_a)
  end

  def test_a_slice_of_a_slice
    array = CArray.double(20).seq!
    inner = array[4..15][2..9]
    inner[0] = 1.0
    doubling(inner, 1...8)
    assert_equal(expected_run(8), array[6..13].to_a)
    assert_equal(5.0, array[5], "the cell before the slice is untouched")
    assert_equal(14.0, array[14], "the cell after the slice is untouched")
  end

  def test_transposed_two_dimensional_view
    matrix = CArray.double(4, 3).seq!
    transposed = matrix.transpose
    result = CArray.double(3, 4)
    CArray.jit_for(*transposed.dim) { |i, j| result[i, j] = transposed[i, j] * 2.0 }
    3.times { |i| 4.times { |j| assert_equal(matrix[j, i] * 2.0, result[i, j]) } }
  end

  def test_entity_takes_the_direct_tier
    assert_equal(CArray::JIT::Access::TIER_ENTITY,
                 CArray::JIT::Access.classify(CArray.double(4))[:tier])
  end

  # A gather view has no stride expression, so the box the kernel touches is
  # transferred and written back.
  def test_gathered_view_is_transferred_and_written_back
    source = CArray.double(8).seq!
    selected = source[source > 3.0]
    assert_equal(CArray::JIT::Access::TIER_ATTACH,
                 CArray::JIT::Access.classify(selected)[:tier])
    selected[0] = 1.0
    doubling(selected, 1...4)
    assert_equal([0.0, 1.0, 2.0, 3.0] + expected_run(4), source.to_a)
  end

  # The transfer is proportional to what the kernel asked for.  A whole-view
  # materialise would cost the same for ten cells as for ten million, and a
  # cost that does not scale with the work is one the caller cannot reason
  # about.
  def test_only_the_requested_region_crosses
    source = CArray.double(64).seq!
    gathered = source[source >= 0.0]

    seen = nil
    CArray::JIT::Access.open([gathered], [true], [[10]], [[4]]) do |bases|
      basis = bases.first
      pointer = Fiddle::Pointer.new(basis[:pointer] + 10 * 8, 4 * 8)
      seen = pointer[0, 4 * 8].unpack("d4")
      pointer[0, 8] = [-1.0].pack("d")
    end

    assert_equal([10.0, 11.0, 12.0, 13.0], seen,
                 "the buffer holds exactly the requested cells")
    assert_equal(-1.0, source[10], "the region is written back")
    assert_equal(9.0, source[9], "outside the region is untouched")
    assert_equal(14.0, source[14], "outside the region is untouched")
  end

  # The box a gather view has to transfer is the loop range grown by how far
  # the kernel reaches, not the whole view.
  def test_the_region_covers_the_dependency_reach
    source = CArray.double(32).seq!
    gathered = source[source >= 0.0]
    gathered[10] = 1.0
    CArray.jit_for(11...14) { |i| gathered[i] = gathered[i-1] * 2.0 }
    assert_equal([1.0, 2.0, 4.0, 8.0], source[10..13].to_a)
    assert_equal(9.0, source[9])
    assert_equal(14.0, source[14])
  end

  # A view that does not fold to a stride basis is reached a box at a time at
  # any rank, and the box is computed per array and per axis -- two arrays in
  # one kernel need not be read at the same offsets, and one array need not be
  # read at the same offsets on each of its axes.
  def test_two_dimensional_region_is_read_in_the_view_order
    source = CArray.double(4, 5).seq!
    rolled = source.roll(1, 2)
    assert_equal(CArray::JIT::Access::TIER_ATTACH,
                 CArray::JIT::Access.classify(rolled)[:tier])

    result = CArray.double(4, 5)
    CArray.jit_for(4, 5) { |i, j| result[i, j] = rolled[i, j] * 10.0 }
    4.times { |i| 5.times { |j|
      assert_equal(rolled[i, j] * 10.0, result[i, j], "cell #{i},#{j}") } }
  end

  def test_two_dimensional_region_writes_back_only_the_box
    target = CArray.double(4, 5).seq!
    view = target.roll(1, 2)
    CArray.jit_for(1...3, 1...4) { |i, j| view[i, j] = -9.0 }

    (1...3).each do |i|
      (1...4).each do |j|
        assert_equal(-9.0, view[i, j], "cell #{i},#{j} is inside the box")
      end
    end
    assert_equal(6, target.to_a.flatten.count(-9.0),
                 "exactly the six cells of the box were written")
  end

  # A wrong region shape has to come back as a message; a C extension that
  # reads whatever it was handed would crash instead.
  def test_a_malformed_region_is_refused
    array = CArray.double(4)
    assert_raises(TypeError) do
      CArray::JIT::Access.open([array], [true], 0, 4) { }
    end
    assert_raises(ArgumentError) do
      CArray::JIT::Access.open([array], [true], [[0]], nil) { }
    end
    assert_raises(ArgumentError) do
      CArray::JIT::Access.open([array], [true], [[0], [0]], [[4], [4]]) { }
    end
    assert_raises(ArgumentError) do
      CArray::JIT::Access.open([CArray.double(4, 4)], [true], [[0]], [[4]]) { }
    end
  end

  def test_two_dimensional_region_covers_the_halo
    base = CArray.double(5, 5).seq!
    view = base.roll(1, 1)
    result = CArray.double(5, 5)
    CArray.jit_for(1...4, 1...4) { |i, j|
      result[i, j] = view[i-1, j] + view[i+1, j] + view[i, j-1] + view[i, j+1]
    }
    (1...4).each do |i|
      (1...4).each do |j|
        assert_equal(view[i-1, j] + view[i+1, j] + view[i, j-1] + view[i, j+1],
                     result[i, j], "cell #{i},#{j}")
      end
    end
  end

  def test_region_outside_the_array_is_refused
    source = CArray.double(8).seq!
    gathered = source[source >= 0.0]
    assert_raises(ArgumentError) do
      CArray::JIT::Access.open([gathered], [true], [[6]], [[10]]) { }
    end
  end

  # A mask is a CArray of the same shape and, for a view, the same kind of
  # view, so it opens by the same tier logic as the data.
  def test_a_masked_view_reports_its_mask_basis
    matrix = CArray.double(4, 5).seq!
    matrix[1, 2] = UNDEF
    column = matrix[nil, 2]
    CArray::JIT::Access.open([column], [true]) do |bases|
      basis = bases.first
      assert_equal(CArray::JIT::Access::TIER_STRIDE, basis[:tier])
      refute_nil(basis[:mask_pointer])
      # The value strides step in bytes, the mask's in elements, so the same
      # geometry shows up divided by the element size.
      assert_equal(basis[:strides].first / matrix.bytes, basis[:mask_strides].first)
    end
  end

  def test_an_unmasked_array_reports_no_mask_basis
    CArray::JIT::Access.open([CArray.double(4)], [true]) do |bases|
      assert_nil(bases.first[:mask_pointer])
      assert_nil(bases.first[:mask_strides])
    end
  end

  def test_arrays_are_closed_when_the_body_raises
    matrix = CArray.double(4, 2)
    column = matrix[nil, 1]
    assert_raises(RuntimeError) do
      CArray::JIT::Access.open([column], [true]) { raise "boom" }
    end
    column[0] = 5.0
    assert_equal(5.0, matrix[0, 1], "the view still works after the failure")
  end

  # Both loops are compiled; which one runs is decided once, outside the loop.
  def test_a_kernel_carries_both_loops
    values = CArray.double(4)
    kernel = CArray.jit_for(1...4) { |i| values[i] = values[i-1] * 2.0 }
    assert_includes(kernel.c_source, "carray_jit_strided")
    assert_includes(kernel.c_source, "carray_jit_contiguous")
    assert_includes(kernel.c_source, "sizeof(double)")
  end

  # A view with no stride expression is reached a box at a time, and an axis
  # walked by two indices takes the box that covers both of them.
  def test_the_region_covers_both_indices_on_one_axis
    base = CArray.double(6, 4).seq!
    view = base.roll(1, 1)
    assert_equal(CArray::JIT::Access::TIER_ATTACH,
                 CArray::JIT::Access.classify(view)[:tier])
    gram = CArray.double(4, 4)
    CArray.jit_for(4, 4) { |a, b|
      accumulator = 0.0
      (0...6).each { |p| accumulator = accumulator + view[p, a] * view[p, b] }
      gram[a, b] = accumulator
    }
    expected = (0...4).map { |a| (0...4).map { |b|
      (0...6).sum { |p| view[p, a] * view[p, b] } } }
    assert_equal(expected, gram.to_a)
  end

  # The stride tier addresses the fold's root directly, which is sound only if
  # that root owns its memory.  A CARefer over a gather view folds one step and
  # lands on the CASelect, which does not: attaching it materialises a copy,
  # and the kernel's writes used to be thrown away with it.
  def test_a_fold_that_does_not_reach_an_entity_is_not_the_stride_tier
    whole = CArray.double(16).seq!
    view = whole[whole >= 0.0].reshape(4, 4)
    assert(view.class.to_s.include?("Refer"), "the view is a refer over a select")
    assert_equal(CArray::JIT::Access::TIER_ATTACH,
                 CArray::JIT::Access.classify(view)[:tier])

    CArray.jit_for(4, 4) { |i, j| view[i, j] = view[i, j] * 10.0 }
    assert_equal((0...16).map { |k| k * 10.0 }, whole.to_a,
                 "the write reaches the array the view was taken from")
  end

end
