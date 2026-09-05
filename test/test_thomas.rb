require_relative "test_helper"

# The tridiagonal solver written as two jit_for kernels: an ascending sweep
# that writes two arrays at once, and a descending one that reads forward.
#
# It is the case the design had to be able to express.  The forward sweep
# shares a denominator between two outputs, so a kernel that could only write
# one array would have to split into two loops and compute it twice; and the
# back substitution's direction is not stated anywhere, it follows from
# reading x[i+1].
class TestThomas < Minitest::Test

  def build_system (n, seed)
    random = Random.new(seed)
    lower = CArray.double(n)
    diagonal = CArray.double(n)
    upper = CArray.double(n)
    right = CArray.double(n)
    n.times do |i|
      lower[i] = i.zero? ? 0.0 : random.rand(-1.0..1.0)
      upper[i] = (i == n - 1) ? 0.0 : random.rand(-1.0..1.0)
      diagonal[i] = lower[i].abs + upper[i].abs + 1.0 + random.rand
      right[i] = random.rand(-5.0..5.0)
    end
    [lower, diagonal, upper, right]
  end

  def solve_with_jit (lower, diagonal, upper, right)
    n = lower.elements
    modified_upper = CArray.double(n)
    modified_right = CArray.double(n)
    solution = CArray.double(n)

    modified_upper[0] = upper[0] / diagonal[0]
    modified_right[0] = right[0] / diagonal[0]

    CArray.jit_for(1...n) { |i|
      denominator = diagonal[i] - lower[i] * modified_upper[i-1]
      modified_upper[i] = upper[i] / denominator
      modified_right[i] = (right[i] - lower[i] * modified_right[i-1]) / denominator
    }

    solution[n-1] = modified_right[n-1]
    CArray.jit_for((n-2).step(0, -1)) { |i|
      solution[i] = modified_right[i] - modified_upper[i] * solution[i+1]
    }
    solution
  end

  def solve_in_ruby (lower, diagonal, upper, right)
    n = lower.elements
    modified_upper = Array.new(n, 0.0)
    modified_right = Array.new(n, 0.0)
    solution = Array.new(n, 0.0)

    modified_upper[0] = upper[0] / diagonal[0]
    modified_right[0] = right[0] / diagonal[0]
    (1...n).each do |i|
      denominator = diagonal[i] - lower[i] * modified_upper[i-1]
      modified_upper[i] = upper[i] / denominator
      modified_right[i] = (right[i] - lower[i] * modified_right[i-1]) / denominator
    end
    solution[n-1] = modified_right[n-1]
    (n-2).downto(0) do |i|
      solution[i] = modified_right[i] - modified_upper[i] * solution[i+1]
    end
    solution
  end

  def residual (lower, diagonal, upper, right, solution)
    n = lower.elements
    (0...n).map { |i|
      value = diagonal[i] * solution[i]
      value += lower[i] * solution[i-1] if i > 0
      value += upper[i] * solution[i+1] if i < n - 1
      (value - right[i]).abs
    }.max
  end

  def test_matches_a_plain_ruby_solver_bit_for_bit
    [3, 17, 200].each do |n|
      system = build_system(n, 1234 + n)
      jit = solve_with_jit(*system)
      plain = solve_in_ruby(*system)
      n.times do |i|
        assert_bits_equal(plain[i], jit[i], "n=#{n}, cell #{i}")
      end
    end
  end

  def test_residual_is_small
    system = build_system(500, 99)
    solution = solve_with_jit(*system)
    assert_operator(residual(*system, solution), :<, 1e-10)
  end

  def test_forward_sweep_writes_two_arrays_in_one_pass
    n = 8
    lower, diagonal, upper, right = build_system(n, 7)
    modified_upper = CArray.double(n)
    modified_right = CArray.double(n)
    modified_upper[0] = upper[0] / diagonal[0]
    modified_right[0] = right[0] / diagonal[0]

    kernel = CArray.jit_for(1...n) { |i|
      denominator = diagonal[i] - lower[i] * modified_upper[i-1]
      modified_upper[i] = upper[i] / denominator
      modified_right[i] = (right[i] - lower[i] * modified_right[i-1]) / denominator
    }

    assert_equal(2, kernel.written_arrays.size,
                 "both outputs are written by the one kernel")
    # Once per loop body, and there are two bodies (strided and contiguous).
    # Counted past the header comment, which quotes the block itself.
    generated = kernel.c_source.split("*/", 2).last
    assert_equal(2, generated.scan("denominator =").size,
                 "the shared denominator is computed once per iteration")
  end

  def test_the_two_sweeps_run_in_opposite_directions
    n = 8
    lower, diagonal, upper, right = build_system(n, 5)
    modified_upper = CArray.double(n)
    modified_right = CArray.double(n)
    solution = CArray.double(n)
    modified_upper[0] = upper[0] / diagonal[0]
    modified_right[0] = right[0] / diagonal[0]

    forward = CArray.jit_for(1...n) { |i|
      denominator = diagonal[i] - lower[i] * modified_upper[i-1]
      modified_upper[i] = upper[i] / denominator
      modified_right[i] = (right[i] - lower[i] * modified_right[i-1]) / denominator
    }
    assert_match(/i\+\+\)/, forward.c_source)

    solution[n-1] = modified_right[n-1]
    backward = CArray.jit_for((n-2).step(0, -1)) { |i|
      solution[i] = modified_right[i] - modified_upper[i] * solution[i+1]
    }
    assert_match(/i--\)/, backward.c_source)
  end

end
