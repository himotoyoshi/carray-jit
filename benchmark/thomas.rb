# The tridiagonal solver, four ways.
#
# The Thomas algorithm is two sweeps that cannot be vectorised -- each cell
# depends on the one before it -- so it is a fair test of what a compiled
# per-cell loop is worth.
#
# It also lands ahead of LAPACK's ?gtsv, which is not a claim about the
# compiler: ?gtsv does LU with partial pivoting and solves systems that are
# not diagonally dominant, while this solves the ones that are.  Skipping the
# pivot is the whole difference.  What the comparison is actually good for is
# the other direction -- ?gtsv exists, so this can be checked against it,
# which the algorithms that have no LAPACK entry point cannot be.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "carray/jit"
# A backend gem has to be loaded for LAPACK to be reachable at all.
LAPACK = begin
  require "carray-linalg"
  begin
    require "carray-linalg-accelerate"
  rescue LoadError
    require "carray-linalg-openblas"
  end
  true
rescue LoadError
  false
end

N = 1_000_000
SAMPLES = 5

def median (list) = list.sort[list.size / 2]

def build_system (n)
  random = Random.new(20260901)
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

def solve_with_jit (a, b, c, d)
  n = a.elements
  cc = CArray.double(n)
  dd = CArray.double(n)
  x = CArray.double(n)
  cc[0] = c[0] / b[0]
  dd[0] = d[0] / b[0]
  CArray.jit_for(1...n) { |i|
    denominator = b[i] - a[i] * cc[i-1]
    cc[i] = c[i] / denominator
    dd[i] = (d[i] - a[i] * dd[i-1]) / denominator
  }
  x[n-1] = dd[n-1]
  CArray.jit_for((n-2).step(0, -1)) { |i| x[i] = dd[i] - cc[i] * x[i+1] }
  x
end

def solve_in_ruby_over_carray (a, b, c, d)
  n = a.elements
  cc = CArray.double(n)
  dd = CArray.double(n)
  x = CArray.double(n)
  cc[0] = c[0] / b[0]
  dd[0] = d[0] / b[0]
  (1...n).each do |i|
    denominator = b[i] - a[i] * cc[i-1]
    cc[i] = c[i] / denominator
    dd[i] = (d[i] - a[i] * dd[i-1]) / denominator
  end
  x[n-1] = dd[n-1]
  (n-2).downto(0) { |i| x[i] = dd[i] - cc[i] * x[i+1] }
  x
end

def solve_in_ruby_over_arrays (a, b, c, d)
  n = a.elements
  la, lb, lc, ld = a.to_a, b.to_a, c.to_a, d.to_a
  cc = Array.new(n, 0.0)
  dd = Array.new(n, 0.0)
  x = Array.new(n, 0.0)
  cc[0] = lc[0] / lb[0]
  dd[0] = ld[0] / lb[0]
  (1...n).each do |i|
    denominator = lb[i] - la[i] * cc[i-1]
    cc[i] = lc[i] / denominator
    dd[i] = (ld[i] - la[i] * dd[i-1]) / denominator
  end
  x[n-1] = dd[n-1]
  (n-2).downto(0) { |i| x[i] = dd[i] - cc[i] * x[i+1] }
  x
end

system = build_system(N)
reference = solve_with_jit(*system)          # also warms the kernel cache

def timed (samples)
  median(samples.times.map { Benchmark.realtime { yield } })
end

jit = timed(SAMPLES) { solve_with_jit(*system) }
over_carray = timed(SAMPLES) { solve_in_ruby_over_carray(*system) }
over_arrays = timed(SAMPLES) { solve_in_ruby_over_arrays(*system) }

puts "n = #{N}"
puts format("jit_for (compiled)      %8.1f ms   %6.1f ns/element", jit * 1e3, jit / N * 1e9)
puts format("Ruby loop over CArray    %8.1f ms   %6.1f ns/element  %5.0fx",
            over_carray * 1e3, over_carray / N * 1e9, over_carray / jit)
puts format("Ruby loop over Array     %8.1f ms   %6.1f ns/element  %5.0fx",
            over_arrays * 1e3, over_arrays / N * 1e9, over_arrays / jit)

if LAPACK
  # ?gtsv overwrites all four of its arguments, so each sample needs fresh
  # copies -- but making them is not part of solving, so they are made
  # outside the timed region.  Timing them alongside the solve would have
  # charged LAPACK for 32 MB of copying this kernel never does.
  copy_cost = median(SAMPLES.times.map {
    Benchmark.realtime { system.map { |v| v.copy } }
  })
  lapack = median(SAMPLES.times.map {
    a, b, c, d = system.map { |v| v.copy }
    right = d[nil, :_]
    Benchmark.realtime { CArray::Linalg.solve_tridiagonal(a[1..-1], b, c[0..-2], right) }
  })
  puts format("  (copying ?gtsv's four arguments, excluded: %.1f ms)", copy_cost * 1e3)
  puts format("LAPACK ?gtsv             %8.1f ms   %6.1f ns/element  %5.2fx",
              lapack * 1e3, lapack / N * 1e9, lapack / jit)

  a, b, c, d = system.map { |v| v.copy }
  solution = CArray::Linalg.solve_tridiagonal(a[1..-1], b, c[0..-2], d[nil, :_])
  difference = (0...N).map { |i| (solution[i, 0] - reference[i]).abs }.max
  puts format("largest difference from LAPACK: %.3g", difference)
end
