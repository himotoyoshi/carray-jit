require_relative "test_helper"

# An array the block only hands to a C function whole is not an array the
# loop walks, so the expression's shape has nothing to say about it.
#
# In the whole-array spellings it used to be lined up with the operands all
# the same: one of a different length died in `broadcast_to`, naming an axis
# and saying nothing about the call it was written for.  It now joins after
# the broadcast, which is what a generator's state already did and for the
# same reason.
#
# What decides which arrays those are is the declaration, not the spelling.
# A bare array name in an argument position looks like an address pass and
# need not be one: in this spelling a bare name is a cell, so a parameter
# taking a `double` by value walks the array cell by cell.
class TestAddressArrays < Minitest::Test

  def dot4
    CArray.jit_function(
      "double dot4(const double x[4], const double y[4])") { |x, y|
      x[0] * y[0] + x[1] * y[1] + x[2] * y[2] + x[3] * y[3]
    }
  end

  def sum4
    CArray.jit_function("double s4(const double x[4])") { |x|
      x[0] + x[1] + x[2] + x[3]
    }
  end

  # The registry lives as long as the process, so a kernel another test
  # already compiled would not show up as new.  Cleared first; the objects
  # are still on disk, so this costs a lookup and not a compile.
  def kernels_made
    CArray::JIT.clear_registry
    yield
    CArray::JIT.registry.each_value.to_a
  end

  # ---------- the shape it no longer has to agree with ----------

  def test_a_shorter_weight_is_not_lined_up_with_the_operands
    weights = CArray.double(4).seq!(1.0)
    a = CArray.double(7).seq!(1.0)
    out = CArray.double(7)
    f = dot4
    CArray.jit_each { out = a + f.call(weights, weights) }
    dot = (0...4).inject(0.0) { |total, k| total + weights[k] * weights[k] }
    reference = CArray.double(7) { (0...7).map { |k| a[k] + dot } }
    assert_arrays_bits_equal(reference, out)
  end

  def test_the_same_in_a_map
    weights = CArray.double(4).seq!(1.0)
    a = CArray.double(7).seq!(1.0)
    f = dot4
    out = CArray.jit_map { a + f.call(weights, weights) }
    dot = (0...4).inject(0.0) { |total, k| total + weights[k] * weights[k] }
    reference = CArray.double(7) { (0...7).map { |k| a[k] + dot } }
    assert_arrays_bits_equal(reference, out)
  end

  def test_a_longer_weight_is_not_lined_up_either
    weights = CArray.double(64).seq!(1.0)
    a = CArray.double(5).seq!(1.0)
    out = CArray.double(5)
    f = sum4
    CArray.jit_each { out = a + f.call(weights) }
    first_four = (0...4).inject(0.0) { |total, k| total + weights[k] }
    reference = CArray.double(5) { (0...5).map { |k| a[k] + first_four } }
    assert_arrays_bits_equal(reference, out)
  end

  # `jit_stencil` never had the problem -- its operands come from its
  # arguments and it does not broadcast the captures -- and this says so
  # rather than leaving it to be assumed.
  def test_a_stencil_takes_a_captured_weight_of_its_own_length
    weights = CArray.double(4).seq!(1.0)
    image = CArray.double(6, 6).seq!
    f = dot4
    out = CArray.jit_stencil(image, border: :clamp) { |win|
      win[0, 0] + f.call(weights, weights)
    }
    dot = (0...4).inject(0.0) { |total, k| total + weights[k] * weights[k] }
    assert_equal(image[3, 3] + dot, out[3, 3])
  end

  # ---------- it is not walked, whatever its length ----------

  def test_the_handed_array_is_not_an_operand
    weights = CArray.double(4).seq!(1.0)
    a = CArray.double(7).seq!(1.0)
    out = CArray.double(7)
    f = dot4
    made = kernels_made {
      CArray.jit_each { out = a + f.call(weights, weights) }
    }
    kernel = made.first
    assert_equal([:a, :out], kernel.arrays.sort,
                 "only the arrays the loop walks are operands")
    assert_includes(kernel.address_arrays, :weights)
    refute_match(/weights_s0/, kernel.c_source,
                 "an array handed over whole has no stride to walk by")
  end

  # A weight that happens to be the operands' length was never refused, since
  # a matching shape broadcasts.  It is still not walked.
  def test_a_weight_of_the_operands_length_is_still_not_walked
    weights = CArray.double(6).seq!(1.0)
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    f = dot4
    made = kernels_made { CArray.jit_each { out = a + f.call(weights, weights) } }
    kernel = made.first
    refute_includes(kernel.arrays, :weights)
    assert_includes(kernel.address_arrays, :weights)
    dot = (0...4).inject(0.0) { |total, k| total + weights[k] * weights[k] }
    assert_equal((0...6).map { |k| a[k] + dot }, out.to_a)
  end

  # ---------- what the callee writes comes back ----------

  def test_a_callee_writes_through_a_parameter_that_is_not_const
    fill = CArray.jit_function("double fill1(double slot[1], double v)") { |slot, v|
      slot[0] = v
      slot[0]
    }
    slot = CArray.double(1)
    source = CArray.double(5).seq!(1.0)
    sink = CArray.double(5)
    CArray.jit_each { sink = fill.call(slot, source) }
    assert_equal([1.0, 2.0, 3.0, 4.0, 5.0], sink.to_a)
    assert_equal([5.0], slot.to_a,
                 "the write lands in the caller's array, not in a stretched " \
                 "view of it")
  end

  # ---------- a name that is also read by cell ----------

  def test_an_array_both_walked_and_handed_over_is_still_lined_up
    v = CArray.double(4).seq!(2.0)
    out = CArray.double(4)
    f = sum4
    made = kernels_made { CArray.jit_each { out = v + f.call(v) } }
    kernel = made.first
    assert_includes(kernel.arrays, :v, "it is read by cell as well")
    total = (0...4).inject(0.0) { |t, k| t + v[k] }
    assert_equal((0...4).map { |k| v[k] + total }, out.to_a)
  end

  def test_a_shape_that_does_not_line_up_is_still_refused_where_it_is_walked
    v = CArray.double(4).seq!(2.0)
    out = CArray.double(7)
    f = sum4
    error = assert_raises(RuntimeError) do
      CArray.jit_each { out = v + f.call(v) }
    end
    assert_match(/broadcast/, error.message,
                 "an array read by cell lines up as it always did")
  end

  # A parameter that takes a number by value reads the cell, so the array is
  # walked -- which is why the declaration decides and not the spelling.
  def test_a_by_value_parameter_walks_the_array
    twice = CArray.jit_function("double twice(double x)") { |x| x * 2.0 }
    a = CArray.double(5).seq!(1.0)
    out = CArray.double(5)
    made = kernels_made { CArray.jit_each { out = twice.call(a) } }
    kernel = made.first
    assert_includes(kernel.arrays, :a, "a bare name here is a cell")
    assert_empty(kernel.address_arrays)
    assert_equal((0...5).map { |k| a[k] * 2.0 }, out.to_a)
  end

  # ---------- masks ----------

  # Handing a masked array to a C function is refused where the call is made,
  # the C having no mask to read.  What this adds is that the kernel is not
  # compiled as a masked one on the way to that refusal.
  def test_a_masked_array_handed_over_is_refused_and_the_kernel_is_unmasked
    masked = CArray.double(4).seq!(1.0)
    masked[1] = UNDEF
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    f = sum4
    made = nil
    error = assert_raises(CArray::JIT::Unsupported) do
      made = kernels_made { CArray.jit_each { out = a + f.call(masked) } }
    end
    assert_match(/carries a mask and is handed to a C function/, error.message)
    assert_match(/strip_mask/, error.message)
    kernel = CArray::JIT.registry.each_value.find { |k|
      k.address_arrays.include?(:masked)
    }
    refute_nil(kernel, "the kernel was compiled before the call refused")
    refute(kernel.masked,
           "a mask the C cannot read is not a mask the kernel carries")
  end

  def test_stripping_the_mask_is_the_way_through
    holed = CArray.double(4).seq!(1.0)
    holed[1] = UNDEF
    a = CArray.double(6).seq!(1.0)
    out = CArray.double(6)
    filled = holed.strip_mask(0.0)
    f = sum4
    CArray.jit_each { out = a + f.call(filled) }
    total = 1.0 + 0.0 + 3.0 + 4.0
    assert_equal((0...6).map { |k| a[k] + total }, out.to_a)
  end

  # ---------- a block with nothing to walk ----------

  def test_a_block_whose_only_array_is_handed_over_says_so
    weights = CArray.double(4).seq!(1.0)
    f = sum4
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_map { f.call(weights) }
    end
    assert_match(/reaches no array to walk/, error.message)
    assert_match(/`weights` is handed to a C function whole/, error.message)
    assert_match(/does not say how many cells/, error.message)
    assert_match(/`CArray\.jit_for` with a count/, error.message)
  end

  def test_the_same_in_a_jit_each_block
    weights = CArray.double(4).seq!(1.0)
    f = sum4
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_each { f.call(weights) }
    end
    assert_match(/reaches no array to walk/, error.message)
  end

  # `jit_for` says how many cells there are itself, so it never needed one.
  def test_jit_for_takes_a_block_whose_only_array_is_handed_over
    weights = CArray.double(4).seq!(1.0)
    out = CArray.double(3)
    f = sum4
    CArray.jit_for(3) { |i| out[i] = f.call(weights) }
    total = (0...4).inject(0.0) { |t, k| t + weights[k] }
    assert_equal([total] * 3, out.to_a)
  end

  # ---------- the static reading agrees with the analyzer ----------

  # The split has to happen before the analyzer runs, so it is a static
  # reading of the block, and the analyzer's answer is the final one.  The two
  # answer different questions and are not the same set: the kernel's
  # `address_arrays` is every array handed over by address, which an array
  # read by cell as well is one of, while the scan answers the narrower
  # question the broadcast needs -- handed over and *not* walked.
  #
  # So what has to hold is not equality but safety, in both directions: every
  # name the scan takes out of the line-up is one the kernel does hand over,
  # and is not one the kernel walks.  Get either wrong and an operand loses
  # its strides.
  def test_the_scan_never_takes_out_an_array_the_kernel_walks
    weights = CArray.double(4).seq!(1.0)
    other = CArray.double(4).seq!(3.0)
    a = CArray.double(7).seq!(1.0)
    out = CArray.double(7)
    f = dot4
    g = sum4
    twice = CArray.jit_function("double twice2(double x)") { |x| x * 2.0 }

    # The fifth reads `weights` by cell as well as handing it over, so its
    # operands are four cells long and it writes somewhere of that length.
    short = CArray.double(4)

    [proc { out = a + f.call(weights, weights) },
     proc { out = a + f.call(weights, other) },
     proc { out = a + g.call(weights) + g.call(other) },
     proc { out = a + twice.call(a) },
     proc { short = weights + g.call(weights) },
     proc { out = a + g.call(weights) + twice.call(a) }].each_with_index do |block, n|
      made = kernels_made { CArray.jit_each(&block) }
      kernel = made.first
      node, source, = CArray::JIT.send(:read_block, block)
      captured = CArray::JIT.send(:split_captures,
                                  CArray::JIT.send(:capture_names, source, node),
                                  block.binding)
      scanned = CArray::JIT::Analyzer.address_array_names(
        source, node: node, c_functions: captured[2])
      scanned.each do |name|
        assert_includes(kernel.address_arrays, name,
                        "block #{n}: the scan took `#{name}` out of the " \
                        "line-up, so the kernel had better be handing it over")
        refute_includes(kernel.arrays, name,
                        "block #{n}: `#{name}` was taken out of the line-up " \
                        "and is walked after all")
      end
    end
  end

  # And the case that keeps the two sets apart, spelled out: an array read by
  # cell *and* handed over stays an operand, and the scan leaves it alone.
  def test_an_array_used_both_ways_is_in_the_line_up_and_not_in_the_scan
    weights = CArray.double(4).seq!(1.0)
    short = CArray.double(4)
    g = sum4
    block = proc { short = weights + g.call(weights) }
    made = kernels_made { CArray.jit_each(&block) }
    kernel = made.first
    assert_includes(kernel.arrays, :weights, "it is walked")
    assert_includes(kernel.address_arrays, :weights, "and handed over")
    node, source, = CArray::JIT.send(:read_block, block)
    captured = CArray::JIT.send(:split_captures,
                                CArray::JIT.send(:capture_names, source, node),
                                block.binding)
    assert_empty(CArray::JIT::Analyzer.address_array_names(
                   source, node: node, c_functions: captured[2]),
                 "the scan leaves an array it cannot take out alone")
    total = (0...4).inject(0.0) { |t, k| t + weights[k] }
    assert_equal((0...4).map { |k| weights[k] + total }, short.to_a)
  end

  # ---------- alongside a generator ----------

  # Two things now join after the broadcast rather than one.
  def test_a_generators_state_and_a_handed_array_both_join_after
    weights = CArray.double(4).seq!(1.0)
    a = CArray.double(7).seq!(1.0)
    out = CArray.double(7)
    f = dot4
    generator = CArray::Rng.new(seed: 4)
    CArray.jit_each { out = a + f.call(weights, weights) + random(rng: generator) }
    dot = (0...4).inject(0.0) { |total, k| total + weights[k] * weights[k] }
    (0...7).each do |k|
      drawn = out[k] - a[k] - dot
      assert_operator(drawn, :>=, 0.0, "cell #{k} drew #{drawn}")
      assert_operator(drawn, :<, 1.0, "cell #{k} drew #{drawn}")
    end
  end

end
