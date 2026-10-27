require_relative "test_helper"

# An element-wise pass keeps what its operands' shapes and types decide, and
# re-reads everything else on every call.  What it must never do is let a
# call be run the way an earlier one was when the two differ in something
# the shapes and types do not show: how an operand is laid out, whether it
# has a mask, the type of a scalar.  Each of these is the same block called
# again with one such thing changed, and the answer is checked against the
# one CArray gives.
class TestRunPlan < Minitest::Test

  def setup
    CArray::JIT.clear_registry
  end

  def teardown
    CArray::JIT.clear_registry
  end

  def counting (owner, name)
    original = owner.method(name)
    count = 0
    owner.define_singleton_method(name) do |*arguments, **options, &block|
      count += 1
      original.call(*arguments, **options, &block)
    end
    yield
    count
  ensure
    owner.singleton_class.send(:remove_method, name)
    owner.define_singleton_method(name, original)
  end

  def tier (array)
    CArray::JIT::Access.tier(array)
  end

  # Eight cells at each of the three tiers.  The values are the same, so the
  # answer is too; only the layout differs.
  def entity
    CArray.double(8).seq!(1.0)
  end

  def strided
    matrix = CArray.double(8, 3)
    matrix[nil, 1] = entity
    matrix[nil, 1]
  end

  def transferred
    whole = CArray.double(8).seq!(1.0)
    whole[whole >= 0.0]
  end

  def add (a, b, out)
    CArray.jit_each { out = a + b * 2.0 }
  end

  # One block, handed operands of one shape and one type laid out three
  # ways, over and over.  A tier decides which loop runs the pass, so a plan
  # that remembered the loop without noticing the layout would run a strided
  # operand as a flat run of cells -- and read the wrong ones, quietly.
  def test_one_block_over_every_tier_in_turn
    makers = [:entity, :strided, :transferred]
    assert_equal([CArray::JIT::Access::TIER_ENTITY,
                  CArray::JIT::Access::TIER_STRIDE,
                  CArray::JIT::Access::TIER_XFER],
                 makers.map { |maker| tier(send(maker)) })
    expected = (1..8).map { |k| k + 2.0 * k }
    3.times do |turn|
      makers.each_with_index do |a_is, i|
        makers.each_with_index do |out_is, j|
          b_is = makers[(turn + i + j) % makers.size]
          a = send(a_is)
          b = send(b_is)
          out = send(out_is)
          out[] = 0.0
          add(a, b, out)
          assert_equal(expected, out.to_a,
                       "a #{a_is}, b #{b_is}, out #{out_is}")
        end
      end
    end
  end

  # The loop a pass runs under follows the tier on every call: entity
  # operands go to CArray's sweep, a strided one keeps them here.
  def test_the_loop_follows_the_tier_on_every_call
    swept = 0
    driven = 0
    kernel_class = CArray::JIT::CompiledKernel
    kernel_class.class_eval do
      alias_method :__sweep, :sweep
      alias_method :__call, :call
      define_method(:sweep) { |*arguments| swept += 1; __sweep(*arguments) }
      define_method(:call) { |*arguments, **options|
        driven += 1
        __call(*arguments, **options)
      }
    end
    out = entity
    2.times do
      add(entity, entity, out)
      add(strided, entity, out)
    end
    assert_equal(2, swept)
    assert_equal(2, driven)
  ensure
    kernel_class&.class_eval do
      alias_method :sweep, :__sweep
      alias_method :call, :__call
      remove_method :__sweep, :__call
    end
  end

  # A mask is runtime state that leaves the shape and the type alone.  The
  # block has been planned without one; one appearing has to make the next
  # call a masked one.
  #
  # Through a strided operand as well as an entity one, because the two are
  # run by different loops and only one of them can cover for a stale plan:
  # CArray's sweep, which an entity pass goes to, carries masks of its own
  # accord, and the loop here carries only what the kernel was compiled to.
  def test_a_mask_appearing_after_the_plan
    [:entity, :strided].each do |maker|
      CArray::JIT.clear_registry
      a = send(maker)
      b = entity
      out = CArray.double(8)
      add(a, b, out)
      refute(out.has_mask?, maker)

      b[3] = UNDEF
      add(a, b, out)
      assert_equal((a + b * 2.0).mask.to_a, out.mask.to_a, maker)
      assert_equal((a + b * 2.0).to_a, out.to_a, maker)
    end
  end

  # Two shapes with the same number of cells and the same rank.  Keyed on the
  # count alone, the second would be run over the first's shape.
  #
  # The transposed operand is what makes it tell: it is a strided view, so
  # the pass is run here, axis by axis, and not by CArray's sweep as one run
  # of cells in which the two shapes would be indistinguishable.
  def test_the_same_count_of_cells_in_two_shapes
    [[2, 3], [3, 2], [2, 3], [3, 2]].each do |shape|
      a = CArray.double(*shape.reverse).seq!.T
      b = CArray.double(*shape).seq!(10.0)
      out = CArray.double(*shape)
      CArray.jit_each { out = a * b + 1.0 }
      assert_equal((a * b + 1.0).to_a, out.to_a, shape.inspect)
    end
  end

  # A scalar's type is part of the kernel; its value is not.  An integer
  # array times a Float is a float, and a plan made for an Integer must not
  # answer for one.
  def test_a_scalar_changing_type_between_calls
    a = CArray.int32(4).seq!
    [2, 2.5, 3, 0.5].each do |s|
      result = CArray.jit_map { a * s }
      assert_equal(s.is_a?(Float), result.float?, s.inspect)
      assert_equal((a * s).to_a, result.to_a, s.inspect)
    end
  end

  # A caller alternating between two model states pays for the plan once
  # per state, not once per call.
  def test_two_shapes_in_turn_are_each_planned_once
    small = Array.new(3) { CArray.double(10).seq! }
    large = Array.new(3) { CArray.double(20).seq! }
    step = ->(a, b, out) { CArray.jit_each { out = a + b } }
    calls = counting(CArray::JIT, :compile) do
      5.times do
        step.call(*small)
        step.call(*large)
      end
    end
    assert_equal(2, calls)
    assert_equal((small[0] + small[1]).to_a, small[2].to_a)
    assert_equal((large[0] + large[1]).to_a, large[2].to_a)
  end

  # A plan holds its kernel, so forgetting the kernels forgets the plans.
  def test_clearing_the_registry_forgets_the_plans
    a, b, out = Array.new(3) { entity }
    add(a, b, out)
    calls = counting(CArray::JIT, :compile) do
      CArray::JIT.clear_registry
      add(a, b, out)
      add(a, b, out)
    end
    assert_equal(1, calls)
  end

end
