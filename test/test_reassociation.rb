require_relative "test_helper"

# The licence to take a reduction's accumulator as several partial sums
# instead of one.
#
# What it changes is the order the iterations are grouped in, and nothing
# else: each term is computed exactly as it was, and the answer differs from
# the serial loop's only where floating-point addition's non-associativity
# makes it.  What it buys is the latency of a single dependent chain, which is
# what a serial accumulator spends most of its time in.
#
# The schedule is written into the generated C rather than left to the
# compiler's unroller, because this gem compiles on the machine it runs on: a
# schedule the compiler chose would vary with that machine and with nothing in
# the source saying so.
class TestReassociation < Minitest::Test

  def row_sum (values, length, **licence)
    box = CArray.double(1)
    kernel = CArray.jit_for(1, **licence) { |i|
      accumulator = 0.0
      (0...length).each { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    [box[0], kernel]
  end

  # ---------- what it computes ----------

  # Every trip count around the round: the terms that do not fill one are left
  # to a serial tail, and the incoming value is folded in exactly once.
  def test_every_trip_count
    values = CArray.double(16).seq(1)
    (0..12).each do |length|
      answer, = row_sum(values, length)
      assert_bits_equal((0...length).inject(0.0) { |sum, j| sum + values[j] },
                        answer, "length #{length}")
    end
  end

  def test_a_dot_product
    left = CArray.double(64).seq(1)
    right = CArray.double(64).seq(0.5)
    box = CArray.double(1)
    CArray.jit_for(1) { |i|
      accumulator = 0.0
      (0...64).each { |j| accumulator = accumulator + left[j] * right[j] }
      box[i] = accumulator
    }
    assert_bits_equal((0...64).inject(0.0) { |sum, j| sum + left[j] * right[j] },
                      box[0])
  end

  # A fold whose operator is `*` starts its extra chains from one rather than
  # from zero.
  def test_a_product
    values = CArray.double(10).seq(1) / 4.0
    box = CArray.double(1)
    CArray.jit_for(1) { |i|
      accumulator = 1.0
      (0...10).each { |j| accumulator = accumulator * values[j] }
      box[i] = accumulator
    }
    assert_in_delta((0...10).inject(1.0) { |product, j| product * values[j] },
                    box[0], 1.0e-12)
  end

  # A complex sum adds componentwise in Ruby and in C alike, so the partial
  # sums combine the same way.
  def test_a_complex_sum
    values = CArray.cmplx128(9)
    9.times { |j| values[j] = Complex(j + 1, j * 0.5) }
    box = CArray.cmplx128(1)
    CArray.jit_for(1) { |i|
      accumulator = 0.0 + 0.0i
      (0...9).each { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    assert_bits_equal((0...9).inject(Complex(0.0, 0.0)) { |sum, j| sum + values[j] },
                      box[0])
  end

  def test_a_matrix_multiply
    rows, inner, columns = 5, 7, 3
    left = CArray.double(rows, inner).seq(1)
    right = CArray.double(inner, columns).seq(0.25)
    result = CArray.double(rows, columns)
    CArray.jit_for(rows, columns) { |i, j|
      accumulator = 0.0
      (0...inner).each { |t| accumulator = accumulator + left[i, t] * right[t, j] }
      result[i, j] = accumulator
    }
    rows.times do |i|
      columns.times do |j|
        expected = (0...inner).inject(0.0) { |sum, t| sum + left[i, t] * right[t, j] }
        assert_bits_equal(expected, result[i, j], "cell #{i},#{j}")
      end
    end
  end

  # ---------- what the C says ----------

  def test_the_schedule_is_in_the_source
    values = CArray.double(16).seq(1)
    _, licensed = row_sum(values, 16)
    _, serial = row_sum(values, 16, reassociate: false)

    assert_match(/accumulator__p0/, licensed.c_source)
    assert_match(/accumulator__p3/, licensed.c_source)
    refute_match(/accumulator__p/, serial.c_source)
  end

  # ---------- what it declines to take ----------

  def refuses_to_split (kernel)
    refute_match(/__p0/, kernel.c_source)
  end

  # Reassociating an integer sum would compute the same number, so there is
  # nothing to license and nothing is changed.
  def test_an_integer_accumulator
    counts = CArray.int64(8).seq(1)
    box = CArray.int64(1)
    kernel = CArray.jit_for(1) { |i|
      accumulator = 0
      (0...8).each { |j| accumulator = accumulator + counts[j] }
      box[i] = accumulator
    }
    assert_equal 36, box[0]
    refuses_to_split kernel
  end

  # A masked accumulator carries a mask beside its value, and a partial sum
  # would need one each.
  def test_a_masked_kernel
    values = CArray.double(8).seq(1)
    values[3] = UNDEF
    box = CArray.double(1)
    kernel = CArray.jit_for(1) { |i|
      accumulator = 0.0
      (0...8).each { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    assert_equal UNDEF, box[0]
    refuses_to_split kernel
  end

  # Two statements in the loop are not one fold.
  def test_a_loop_that_does_more_than_fold
    values = CArray.double(8).seq(1)
    box = CArray.double(1)
    kernel = CArray.jit_for(1) { |i|
      accumulator = 0.0
      (0...8).each { |j|
        term = values[j] * 2.0
        accumulator = accumulator + term
      }
      box[i] = accumulator
    }
    assert_bits_equal(72.0, box[0])
    refuses_to_split kernel
  end

  # The accumulator has to enter the fold whole.  An exponential average
  # scales it on the way through, so the terms are not a sum at all and the
  # order is the algorithm.
  def test_an_accumulator_that_is_not_folded_whole
    values = CArray.double(8).seq(1)
    box = CArray.double(1)
    kernel = CArray.jit_for(1) { |i|
      accumulator = 0.0
      (0...8).each { |j| accumulator = accumulator * 0.5 + values[j] }
      box[i] = accumulator
    }
    expected = (0...8).inject(0.0) { |carried, j| carried * 0.5 + values[j] }
    assert_bits_equal(expected, box[0])
    refuses_to_split kernel
  end

  # An extent written out is known when the kernel is generated, and one
  # shorter than a round has nothing for the chains to do -- so it keeps the
  # serial loop rather than paying to set them up.  An extent the kernel is
  # handed is not known there, and takes the chains whatever it turns out to
  # be.
  def test_a_written_out_extent_shorter_than_a_round
    values = CArray.double(8).seq(1)
    box = CArray.double(1)
    short = CArray.jit_for(1) { |i|
      accumulator = 0.0
      (0...4).each { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    assert_bits_equal(10.0, box[0])
    refuses_to_split short

    long = CArray.jit_for(1) { |i|
      accumulator = 0.0
      (0...8).each { |j| accumulator = accumulator + values[j] }
      box[i] = accumulator
    }
    assert_bits_equal(36.0, box[0])
    assert_match(/accumulator__p0/, long.c_source)
  end

  # ---------- a contraction ----------

  # A contraction says which indices are summed and nothing about the order,
  # so there is no order of the caller's to override and the accumulator is
  # split as `jit_for`'s is.
  def contracted_kernel (left, right, into)
    CArray.jit_contract { |i, j, t| into[i,j] = left[i,t] * right[t,j] }
  end

  def test_a_contraction_splits_its_sum
    left = CArray.double(2, 16).seq(1)
    right = CArray.double(16, 2).seq(1)
    into = CArray.double(2, 2)
    kernel = contracted_kernel(left, right, into)
    assert_match(/__p0/, kernel.c_source)
    assert_match(/__p3/, kernel.c_source)
  end

  # There is no per-call licence -- a contraction names no loop -- so the
  # process default is what a serial contraction is asked for with.
  def test_a_contraction_under_the_process_default
    left = CArray.double(2, 16).seq(1)
    right = CArray.double(16, 2).seq(1)
    into = CArray.double(2, 2)
    previous = CArray::JIT.reassociate
    begin
      CArray::JIT.reassociate = false
      refuses_to_split contracted_kernel(left, right, into)
    ensure
      CArray::JIT.reassociate = previous
    end
  end

  # And the serial order it then takes is the order a Ruby loop takes, on
  # terms that cancel and so tell the two apart.
  def test_a_serial_contraction_is_the_ruby_order
    random = Random.new(20260907)
    length = 1_000
    values = CArray.double(length) { random.rand(-1.0..1.0) * 1e6 }
    weights = CArray.double(length) { random.rand(-1.0..1.0) }
    serial_sum = (0...length).inject(0.0) { |sum, k| sum + values[k] * weights[k] }

    split = CArray.jit_contract { |k| values[k] * weights[k] }[0]
    previous = CArray::JIT.reassociate
    begin
      CArray::JIT.reassociate = false
      exact = CArray.jit_contract { |k| values[k] * weights[k] }[0]
    ensure
      CArray::JIT.reassociate = previous
    end

    assert_bits_equal(serial_sum, exact)
    refute_equal(serial_sum, split,
                 "the split sum should differ from the serial one on terms " \
                 "that cancel; if it does not, the licence is not reaching " \
                 "the kernel")
  end

  # ---------- where the default comes from ----------

  def test_the_process_default_can_be_turned_off
    values = CArray.double(16).seq(1)
    previous = CArray::JIT.reassociate
    begin
      CArray::JIT.reassociate = false
      _, kernel = row_sum(values, 16)
      refuses_to_split kernel

      # The call site still overrides it, in either direction.
      _, asked = row_sum(values, 16, reassociate: true)
      assert_match(/accumulator__p0/, asked.c_source)
    ensure
      CArray::JIT.reassociate = previous
    end
  end

end
