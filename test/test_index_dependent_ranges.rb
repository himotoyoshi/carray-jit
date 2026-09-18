require_relative "test_helper"

# An inner loop's range may be written over another index: `(p+1...3)`, which
# is the shape a triangular loop takes.
#
# The C for it was always emitted -- `for (int64_t k = p + 1; k < 3; k++)` --
# and what stood in the way was the call, where each index's range is worked
# out as a pair of numbers so that a subscript can be held to its array.  A
# range over another index has no single pair to be, so it is read as an
# interval instead, at its widest.
#
# Widest is the safe direction: it covers every pass the loop can take, so a
# subscript this says is inside really is.  What it costs is that a reach
# nothing actually makes can still be refused, and the message says so.
class TestIndexDependentRanges < Minitest::Test

  # ---------- the shape it was wanted for ----------

  # Example 4 of PROPOSAL_LOCAL_ARRAYS: a 3x3 solve per cell.  The proposal
  # had to write both triangular loops as `if`, and this is the pair.
  def solve (coefficients, triangular)
    ny, nx = coefficients.dim[0, 2]
    x = CArray.double(ny, nx, 3)
    if triangular
      CArray.jit_for(ny, nx) { |i, j|
        m = CArray.double(3, 4)
        3.times { |r| 4.times { |c| m[r, c] = coefficients[i, j, r, c] } }
        3.times { |p|
          (p + 1...3).each { |r|
            f = m[r, p] / m[p, p]
            4.times { |c| m[r, c] -= f * m[p, c] }
          }
        }
        sol = CArray.double(3)
        2.step(0, -1) { |r|
          s = m[r, 3]
          (r + 1...3).each { |c| s -= m[r, c] * sol[c] }
          sol[r] = s / m[r, r]
        }
        3.times { |r| x[i, j, r] = sol[r] }
      }
    else
      CArray.jit_for(ny, nx) { |i, j|
        m = CArray.double(3, 4)
        3.times { |r| 4.times { |c| m[r, c] = coefficients[i, j, r, c] } }
        3.times { |p|
          3.times { |r|
            if r > p
              f = m[r, p] / m[p, p]
              4.times { |c| m[r, c] -= f * m[p, c] }
            end
          }
        }
        sol = CArray.double(3)
        2.step(0, -1) { |r|
          s = m[r, 3]
          3.times { |c| s -= m[r, c] * sol[c] if c > r }
          sol[r] = s / m[r, r]
        }
        3.times { |r| x[i, j, r] = sol[r] }
      }
    end
    x
  end

  def dominant_coefficients (ny, nx)
    coefficients = CArray.double(ny, nx, 3, 4)
    coefficients.seq!(1.0, 0.25)
    ny.times { |i| nx.times { |j| 3.times { |r|
      coefficients[i, j, r, r] = coefficients[i, j, r, r] + 20.0
    } } }
    coefficients
  end

  def test_the_triangular_solve_matches_the_one_written_with_if
    coefficients = dominant_coefficients(3, 4)
    assert_arrays_bits_equal(solve(coefficients, false).flatten,
                             solve(coefficients, true).flatten)
  end

  # Example 5: Neville, whose inner range is `(0...4-m)`.
  def test_neville_with_a_dependent_range_matches_the_if_version
    triangular = CArray.jit_function(
      "double nv_tri(double x, const double xs[4], const double ys[4])") { |x, xs, ys|
      t = CArray.double(4)
      4.times { |k| t[k] = ys[k] }
      (1...4).each { |m|
        (0...4 - m).each { |k|
          t[k] = ((x - xs[k + m]) * t[k] + (xs[k] - x) * t[k + 1]) /
                 (xs[k] - xs[k + m])
        }
      }
      t[0]
    }
    guarded = CArray.jit_function(
      "double nv_if(double x, const double xs[4], const double ys[4])") { |x, xs, ys|
      t = CArray.double(4)
      4.times { |k| t[k] = ys[k] }
      (1...4).each { |m|
        (0...3).each { |k|
          if k < 4 - m
            t[k] = ((x - xs[k + m]) * t[k] + (xs[k] - x) * t[k + 1]) /
                   (xs[k] - xs[k + m])
          end
        }
      }
      t[0]
    }
    xs = CArray.double(4)
    ys = CArray.double(4)
    [0.0, 1.0, 2.0, 3.0].each_with_index { |v, k| xs[k] = v }
    [1.0, 2.5, 0.5, 4.0].each_with_index { |v, k| ys[k] = v }
    [0.5, 1.5, 2.25, 2.75].each do |query|
      assert_bits_equal(guarded.call(query, xs, ys),
                        triangular.call(query, xs, ys), "at x = #{query}")
    end
  end

  # ---------- a captured array under a triangular loop ----------

  def test_a_captured_array_read_through_a_dependent_range
    a = CArray.double(3, 3).seq!(1.0)
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      s = 0.0
      3.times { |p| (p + 1...3).each { |k| s = s + a[i, k] } }
      out[i] = s
    }
    reference = (0...3).map { |i|
      s = 0.0
      3.times { |p| (p + 1...3).each { |k| s = s + a[i, k] } }
      s
    }
    assert_arrays_bits_equal(CArray.double(3) { reference }, out)
  end

  def test_a_dependent_range_that_really_does_leave_the_array_is_refused
    a = CArray.double(3, 3).seq!(1.0)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i|
        s = 0.0
        3.times { |p| (p + 1...4).each { |k| s = s + a[i, k] } }
        out[i] = s
      }
    end
    assert_match(/cannot end at 4/, error.message)
  end

  # ---------- the shapes a range may take ----------

  def test_a_range_built_with_a_product
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      s = 0.0
      3.times { |p| (p * 2...8).each { |k| s = s + k } }
      out[i] = s
    }
    reference = (0...3).inject(0.0) { |total, p|
      total + (p * 2...8).inject(0.0) { |t, k| t + k }
    }
    assert_equal([reference] * 2, out.to_a)
  end

  def test_a_triangular_loop_that_counts_down
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      s = 0.0
      3.times { |p| p.step(0, -1) { |k| s = s + k } }
      out[i] = s
    }
    reference = (0...3).inject(0.0) { |total, p|
      total + p.step(0, -1).inject(0.0) { |t, k| t + k }
    }
    assert_equal([reference] * 2, out.to_a)
  end

  def test_a_range_over_the_kernels_own_index
    a = CArray.double(4).seq!(1.0)
    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      s = 0.0
      (i...4).each { |k| s = s + a[k] }
      out[i] = s
    }
    reference = (0...4).map { |i| (i...4).inject(0.0) { |t, k| t + a[k] } }
    assert_arrays_bits_equal(CArray.double(4) { reference }, out)
  end

  def test_a_range_nested_two_deep
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      s = 0.0
      4.times { |p| (p...4).each { |q| (q...4).each { |r| s = s + r } } }
      out[i] = s
    }
    reference = 0.0
    4.times { |p| (p...4).each { |q| (q...4).each { |r| reference += r } } }
    assert_equal([reference] * 2, out.to_a)
  end

  # ---------- what the widest reading costs ----------

  # `(p-1)*(p-1)` is never negative, but the interval of `p-1` straddles zero,
  # so its square is read as reaching -1.  The loop never starts there; the
  # widest reading does, and the message has to say why.
  def test_a_reach_the_loop_never_makes_is_refused_and_says_why
    a = CArray.double(3, 3).seq!(1.0)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i|
        s = 0.0
        3.times { |p| ((p - 1) * (p - 1)...3).each { |k| s = s + a[i, k] } }
        out[i] = s
      }
    end
    assert_match(/cannot start at -1/, error.message)
    assert_match(/is written over `p`/, error.message)
    assert_match(/read here at its widest/, error.message)
    assert_match(/further than it goes on any one pass/, error.message)
  end

  # A range that mentions no index says nothing about widest readings.
  def test_an_ordinary_range_keeps_its_own_message
    a = CArray.double(3).seq!(1.0)
    out = CArray.double(3)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(3) { |i|
        s = 0.0
        (0...4).each { |k| s = s + a[k] }
        out[i] = s
      }
    end
    assert_match(/cannot end at 4/, error.message)
    refute_match(/widest/, error.message)
  end

  # ---------- a local array under a dependent range ----------

  # The compile-time check only covers axes whose range is literal
  # throughout, so an axis indexed by a dependent range is checked at the
  # access instead.
  def test_a_local_array_out_of_range_under_a_dependent_range_raises
    out = CArray.double(2)
    assert_raises(IndexError) do
      CArray.jit_for(2) { |i|
        w = CArray.double(3)
        3.times { |p| (p...6).each { |k| w[k] = 1.0 } }
        out[i] = w[0]
      }
    end
  end

  def test_a_local_array_inside_its_shape_is_taken
    out = CArray.double(2)
    CArray.jit_for(2) { |i|
      w = CArray.double(4)
      (0...4).each { |k| w[k] = 0.0 }
      3.times { |p| (p...3).each { |k| w[k] = w[k] + 1.0 } }
      out[i] = w[0] + w[1] + w[2]
    }
    # w[0] is written once (p = 0), w[1] twice, w[2] three times.
    assert_equal([6.0, 6.0], out.to_a)
  end

  # ---------- every entry point ----------

  def test_a_dependent_range_in_every_entry_point
    a = CArray.double(4).seq!(1.0)

    out = CArray.double(4)
    CArray.jit_for(4) { |i|
      s = 0.0
      3.times { |p| (p + 1...3).each { |k| s = s + k } }
      out[i] = s
    }
    assert_equal([5.0] * 4, out.to_a, "jit_for")

    each = CArray.double(4)
    CArray.jit_each {
      s = 0.0
      3.times { |p| (p + 1...3).each { |k| s = s + a * k } }
      each = s
    }
    assert_equal((0...4).map { |k| a[k] * 5.0 }, each.to_a, "jit_each")

    mapped = CArray.jit_map {
      s = 0.0
      3.times { |p| (p + 1...3).each { |k| s = s + a * k } }
      s
    }
    assert_equal((0...4).map { |k| a[k] * 5.0 }, mapped.to_a, "jit_map")

    image = CArray.double(6, 6).seq!
    stencilled = CArray.jit_stencil(image, border: :clamp) { |win|
      s = 0.0
      3.times { |p| (p + 1...3).each { |k| s = s + win[0, 0] * k } }
      s
    }
    assert_equal(image[2, 2] * 5.0, stencilled[2, 2], "jit_stencil")

    body = CArray.jit_function("double tri(double x)") { |x|
      s = 0.0
      3.times { |p| (p + 1...3).each { |k| s = s + x * k } }
      s
    }
    assert_equal(10.0, body.call(2.0), "a function body")
  end

  # A stencil works its frame out from the same ranges, so the border has to
  # come out right too.
  def test_a_stencil_border_under_a_dependent_range
    image = CArray.double(6, 6).seq!
    dependent = CArray.jit_stencil(image, border: :clamp) { |win|
      s = 0.0
      3.times { |p| (p + 1...3).each { |k| s = s + win[-1, 0] * k } }
      s
    }
    guarded = CArray.jit_stencil(image, border: :clamp) { |win|
      s = 0.0
      3.times { |p| (0...3).each { |k| s = s + win[-1, 0] * k if k > p } }
      s
    }
    assert_equal(guarded.to_a, dependent.to_a,
                 "the frame is the same either way it is written")
  end

  # ---------- what a range still may not be ----------

  def test_a_range_over_a_local_variable_is_still_refused
    out = CArray.double(2)
    error = assert_raises(CArray::JIT::Unsupported) do
      CArray.jit_for(2) { |i|
        s = 0.0
        n = 2
        (n...3).each { |k| s = s + k }
        out[i] = s
      }
    end
    assert_match(/an inner loop's range is an integer expression over/,
                 error.message)
    assert_match(/the indices around it/, error.message)
  end

  def test_a_range_over_a_sibling_loops_index_is_refused
    refuse(<<~RUBY, /no value supplied for `p`/, arrays: { :out => "float64" })
      proc { |i|
        s = 0.0
        3.times { |p| s = s + p }
        (p + 1...3).each { |k| s = s + k }
        out[i] = s
      }
    RUBY
  end

  def test_a_range_over_a_deeper_index_is_refused
    refuse(<<~RUBY, /no value supplied for `q`/, arrays: { :out => "float64" })
      proc { |i|
        s = 0.0
        (q + 1...3).each { |p| 3.times { |q| s = s + q } }
        out[i] = s
      }
    RUBY
  end

  # ---------- an ordinary range is untouched ----------

  def test_a_range_of_literals_gives_the_same_span_it_always_did
    a = CArray.double(5).seq!(1.0)
    out = CArray.double(3)
    CArray.jit_for(3) { |i|
      s = 0.0
      (1...4).each { |k| s = s + a[k] }
      out[i] = s
    }
    total = (1...4).inject(0.0) { |t, k| t + a[k] }
    assert_equal([total] * 3, out.to_a)
  end

  def test_a_range_over_a_captured_integer_still_works
    a = CArray.double(5).seq!(1.0)
    out = CArray.double(3)
    limit = 4
    CArray.jit_for(3) { |i|
      s = 0.0
      (1...limit).each { |k| s = s + a[k] }
      out[i] = s
    }
    total = (1...limit).inject(0.0) { |t, k| t + a[k] }
    assert_equal([total] * 3, out.to_a)
  end

end
