require_relative "test_helper"

# A kernel drawing from a generator whose C is CArray's.
#
# The reference throughout is `CArray::Rng#call` -- the same generator,
# reached from Ruby -- and the comparison is exact, because agreement here is
# not statistical.  CArray compiles the generator into its extension and hands
# the same text out as `CArray::Rng::SOURCE`; carray-jit pastes that text
# into the kernel's translation unit.  So the two are not two implementations
# that ought to agree: they are one, and any difference is a bug in the
# pasting rather than in the arithmetic.
#
# What the tests are really watching is the seam that buys: a sequence that
# begins in `CArray#random!` and continues in a kernel, in either order and
# across all three kernel forms, because the state is one array that both
# sides advance in place.
class TestRandom < Minitest::Test

  # The first n draws of a fresh generator, as Ruby takes them.
  def straight (seed, count, generator: :xoshiro256pp)
    rng = CArray::Rng.new(generator, :seed => seed)
    Array.new(count) { rng.rand }
  end

  # ---------- the surface ----------

  def test_jit_rng_makes_a_generator
    rng = CArray.jit_rng(:seed => 4)
    assert_kind_of(CArray::Rng, rng)
    assert_equal(:xoshiro256pp, rng.generator)
    assert_equal(4, rng.seed)
  end

  def test_a_seed_repeats_and_two_seeds_differ
    assert_equal(straight(4, 8), straight(4, 8))
    refute_equal(straight(4, 8), straight(5, 8))
  end

  # A generator made without a seed is given one, so two of them are two
  # sequences rather than the same one twice.
  def test_no_seed_still_differs
    refute_equal(CArray.jit_rng.rand, CArray.jit_rng.rand)
  end

  def test_an_unknown_generator_is_refused
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_rng(:generator => :mersenne)
    end
    assert_match(/not a generator this CArray hands the source of/, error.message)
  end

  # ---------- the three kernel forms ----------

  def test_jit_for_draws_the_same_sequence
    rng = CArray.jit_rng(:seed => 4)
    out = CArray.float64(8)
    CArray.jit_for(8) { |i| out[i] = random(rng: rng) }
    assert_equal(straight(4, 8), out.to_a)
  end

  def test_jit_each_draws_the_same_sequence
    rng = CArray.jit_rng(:seed => 4)
    out = CArray.float64(8)
    CArray.jit_each { out = random(rng: rng) }
    assert_equal(straight(4, 8), out.to_a)
  end

  def test_jit_map_draws_the_same_sequence
    rng = CArray.jit_rng(:seed => 4)
    zero = CArray.float64(8)
    out = CArray.jit_map { zero * 0 + random(rng: rng) }
    assert_equal(straight(4, 8), out.to_a)
  end

  # The state array has four cells and the expression covers eight, so
  # broadcasting the two together is not something that could have worked.
  # It is kept out of the line-up rather than stretched, which is what
  # `jit_each` needs to be usable here at all.
  def test_the_state_is_not_lined_up_with_the_expression
    rng = CArray.jit_rng(:seed => 4)
    out = CArray.float64(101)
    CArray.jit_each { out = random(rng: rng) }
    assert_equal(straight(4, 101), out.to_a)
  end

  def test_a_two_dimensional_pass_draws_in_order
    rng = CArray.jit_rng(:seed => 9)
    out = CArray.float64(4, 5)
    CArray.jit_each { out = random(rng: rng) }
    assert_equal(straight(9, 20), out.flatten.to_a)
  end

  # Large enough to go through CArray's chunked sweep rather than the
  # addressing in kernel.rb.  The state travels the same way on both paths.
  def test_a_sweeping_pass_draws_the_same_sequence
    rng = CArray.jit_rng(:seed => 9)
    out = CArray.float64(20_000)
    CArray.jit_each { out = random(rng: rng) }
    assert_equal(straight(9, 20_000), out.to_a)
  end

  # ---------- the seam ----------

  # The point of putting the generator in CArray: an array filled there and a
  # kernel drawing here are one sequence, not two that were checked against
  # each other.
  def test_the_sequence_continues_from_random_bang_into_a_kernel
    rng = CArray.jit_rng(:seed => 4)
    filled = CArray.float64(5).random!(:rng => rng)
    drawn = CArray.float64(5)
    CArray.jit_for(5) { |i| drawn[i] = random(rng: rng) }
    assert_equal(straight(4, 10), filled.to_a + drawn.to_a)
  end

  def test_the_sequence_continues_from_a_kernel_into_random_bang
    rng = CArray.jit_rng(:seed => 4)
    drawn = CArray.float64(5)
    CArray.jit_for(5) { |i| drawn[i] = random(rng: rng) }
    filled = CArray.float64(5).random!(:rng => rng)
    assert_equal(straight(4, 10), drawn.to_a + filled.to_a)
  end

  # All four ways of reaching one generator, taking turns.  Whichever ran
  # last, the next one picks up the draw after.
  def test_the_four_paths_alternate_over_one_sequence
    rng = CArray.jit_rng(:seed => 4)
    zero = CArray.float64(3)
    got = []

    a = CArray.float64(3)
    CArray.jit_for(3) { |i| a[i] = random(rng: rng) }
    got.concat(a.to_a)

    got.concat(CArray.float64(3).random!(:rng => rng).to_a)

    c = CArray.float64(3)
    CArray.jit_each { c = random(rng: rng) }
    got.concat(c.to_a)

    got.concat(CArray.jit_map { zero * 0 + random(rng: rng) }.to_a)

    got << rng.rand

    assert_equal(straight(4, 13), got)
  end

  # A kernel called twice carries on rather than starting again: the state
  # the first call advanced is the state the second one is handed.
  def test_a_second_call_of_one_kernel_carries_on
    rng = CArray.jit_rng(:seed => 4)
    first = CArray.float64(4)
    second = CArray.float64(4)
    CArray.jit_for(4) { |i| first[i] = random(rng: rng) }
    CArray.jit_for(4) { |i| second[i] = random(rng: rng) }
    assert_equal(straight(4, 8), first.to_a + second.to_a)
  end

  def test_reset_starts_the_sequence_over
    rng = CArray.jit_rng(:seed => 4)
    first = CArray.float64(4)
    CArray.jit_for(4) { |i| first[i] = random(rng: rng) }
    rng.reset
    second = CArray.float64(4)
    CArray.jit_for(4) { |i| second[i] = random(rng: rng) }
    assert_equal(first.to_a, second.to_a)
  end

  # ---------- more than one ----------

  # Two generators in one kernel are two sequences.  Each is exactly the
  # sequence it would have been alone, which is the whole of what
  # "independent" has to mean here.
  def test_two_generators_do_not_interfere
    first = CArray.jit_rng(:seed => 4)
    second = CArray.jit_rng(:seed => 100)
    a = CArray.float64(6)
    b = CArray.float64(6)
    CArray.jit_for(6) { |i| a[i] = random(rng: first); b[i] = random(rng: second) }
    assert_equal(straight(4, 6), a.to_a)
    assert_equal(straight(100, 6), b.to_a)
  end

  # Two names for one generator draw from one sequence, because what carries
  # the sequence is the state array and both names hold the same one.
  def test_two_names_for_one_generator_share_its_sequence
    rng = CArray.jit_rng(:seed => 4)
    same = rng
    out = CArray.float64(6)
    CArray.jit_for(3) { |i| out[2 * i] = random(rng: rng); out[2 * i + 1] = random(rng: same) }
    assert_equal(straight(4, 6), out.to_a)
  end

  # ---------- the seed is data, not code ----------

  # The seed is written into the state and never into the C, so two seeds are
  # one compiled kernel.  If it leaked into the key this would compile twice,
  # and a kernel that is reseeded between calls would compile again each time.
  def test_the_seed_is_not_part_of_the_kernel
    CArray.jit_rng(:seed => 1).tap { |rng|
      out = CArray.float64(4)
      CArray.jit_for(4) { |i| out[i] = random(rng: rng) }
    }
    before = CArray::JIT.registry.size
    CArray.jit_rng(:seed => 2).tap { |rng|
      out = CArray.float64(4)
      CArray.jit_for(4) { |i| out[i] = random(rng: rng) }
    }
    assert_equal(before, CArray::JIT.registry.size,
                 "a second seed compiled a second kernel")
  end

  # ---------- what is refused ----------

  # `random` in a kernel takes `rng:` and nothing else.  Everything
  # `CArray#random!` accepts besides it -- a bound, a range -- is about a
  # whole array and has no answer for one cell, so the refusal says what the
  # one form is rather than listing what is missing.
  # `random` in a kernel takes `rng:` and nothing else.  Everything
  # `CArray#random!` accepts besides it -- a bound, a range -- is about a
  # whole array and has no answer for one cell, so each refusal says what the
  # one form is rather than listing what is missing.
  def test_a_draw_takes_only_rng
    out = CArray.float64(4)
    bare = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| out[i] = random }
    end
    assert_match(/has to say which: `random\(rng: r\)`/, bare.message)

    positional = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| out[i] = random(0.0, 1.0) }
    end
    assert_match(/takes `rng:` and nothing else/, positional.message)
  end

  # `rng:` has to name a generator the block closed over.  A Ruby `Random`
  # is the near miss worth answering: it is a generator, and it is the one a
  # kernel cannot reach.
  def test_rng_must_name_a_generator
    out = CArray.float64(4)
    not_a_generator = ::Random.new(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| out[i] = random(rng: not_a_generator) }
    end
    # A Ruby Random is refused as a capture before the block is even
    # analysed, so the message is the one about captured scalars --
    # which names the entry point that does work.
    assert_match(/a generator draws in an order a kernel does not fix/,
                 error.message)
    assert_match(/CArray\.jit_rng/, error.message)
  end

  # `r.call` is what a reader guesses, so it is answered rather than left to
  # "unsupported method `call`".
  def test_calling_a_generator_says_the_spelling
    rng = CArray.jit_rng(:seed => 4)
    out = CArray.float64(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| out[i] = rng.call }
    end
    assert_match(/a kernel draws from one by naming it/, error.message)
    assert_match(/random\(rng: rng\)/, error.message)
  end

  # A compiled function's arguments are the ones its declaration named, and
  # there is nowhere in it to keep a state.  The message says the way through
  # rather than only that this is not it.
  def test_a_generator_cannot_be_captured_by_a_compiled_function
    rng = CArray.jit_rng(:seed => 4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_function("double f(double x)") { |x| x + random(rng: rng) }
    end
    assert_match(/nowhere to keep its state/, error.message)
    assert_match(/Take the state as a parameter/, error.message)
  end

  # `rand` is Kernel's and still has no place here: it draws from a generator
  # this compiler cannot reach, and the message points at the two that work.
  def test_kernel_rand_is_still_refused
    out = CArray.float64(4)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(4) { |i| out[i] = rand }
    end
    assert_match(/jit_rng/, error.message)
  end

  # A stencil and a contraction are refused, and the message says why rather
  # than only that `call` is not a method the subset has.  Neither runs its
  # block once per cell of the result -- a stencil's border is a second loop
  # over the frame, and a contraction's block is a summand -- so a draw in
  # either would not mean what it looks like.
  def test_a_stencil_says_why_it_does_not_draw
    rng = CArray.jit_rng(:seed => 4)
    a = CArray.float64(10).seq
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_stencil(a) { |w| w[0] + random(rng: rng) }
    end
    assert_match(/a stencil does not draw from one/, error.message)
    assert_match(/border is a second loop/, error.message)
  end

  def test_a_contraction_says_why_it_does_not_draw
    rng = CArray.jit_rng(:seed => 4)
    b = CArray.float64(4, 4).seq
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_contract { |i, j, k| b[i, k] * b[k, j] * random(rng: rng) }
    end
    assert_match(/a contraction does not draw from one/, error.message)
  end

  # ---------- the C that was pasted ----------

  # The kernel's own C carries CArray's text, not a copy of it written here.
  def test_the_generated_c_carries_carrays_source
    rng = CArray.jit_rng(:seed => 4)
    out = CArray.float64(4)
    kernel = CArray.jit_for(4) { |i| out[i] = random(rng: rng) }
    source = kernel.c_source
    assert_includes(source, "ca_xoshiro256pp_next_real")
    # A distinctive line of CArray's text, so that this fails if the kernel
    # ever starts pasting something of its own instead.
    assert_includes(source, "0x9E3779B97F4A7C15ULL")
  end

end
