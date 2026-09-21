# A cubic spline through measured points, natural and clamped
#
# Fitting a C2 curve through n points is a tridiagonal solve: the second
# derivatives at the knots are the unknowns, and each interior knot gives one
# row with three entries in it.  The rows are diagonally dominant, so the
# Thomas algorithm applies -- two sequential sweeps, which is the part an
# array library cannot do for you.
#
# The boundary conditions differ only in the first and last row.  Natural
# asks for zero curvature at the ends, and needs nothing but the samples;
# clamped asks for a given slope there, and needs to be told what it is.  What
# that buys is visible below: where the true curve is still bending at the end,
# the natural spline flattens it, and the error there is several times what it
# is anywhere inside -- the clamped fit removes it.  Not-a-knot asks for the
# first two pieces to be one cubic, and the last two as well, which costs no
# information at all and recovers a good part of the difference.
#
# Evaluating the result is a second kernel, and a different shape of one --
# every query point searches for its interval on its own, so the body is a
# bisection with the bound in the extent.  That search is where the time goes,
# and it is not always needed: query points that arrive sorted -- resampling
# onto a grid gives that -- let the interval be carried forward instead of
# looked up, which is a sweep of the kind the solver already is.  Both are
# here, and they agree bit for bit.
#
#   ruby examples/applications/cubic_spline.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

# The curve being sampled, and its slope -- known here so that the clamped
# ends have something to be given, and so the error can be measured.
def curve (x)      Math.exp(-0.35 * x) * Math.sin(2.0 * x) end
def slope (x)      Math.exp(-0.35 * x) * (2.0 * Math.cos(2.0 * x) - 0.35 * Math.sin(2.0 * x)) end

# ------------------------------------------------------------ the two kernels

# The moments M[i] = S''(x[i]).  Interior rows come from the continuity of the
# first derivative; the two end rows are the boundary condition and are the
# only thing the three of them disagree about.
#
# Not-a-knot is the one that does not fit in a row of its own: asking S''' to
# be continuous at x[1] puts M[0], M[1] and M[2] in one equation, which is a
# band too wide.  Stated the other way round it says M is linear across x[1],
# so M[0] is an extrapolation of the two inside it -- drop the first and last
# unknown, solve the n-2 rows between them, and put the two back afterwards.
# That is what `first_row` and `last_row` are: the same two sweeps, over the
# rows that are actually unknown.
def moments (x, y, n, work, ends)
  a, b, c, d, cc, dd, moment = work

  CArray.jit_for(1...(n-1)) { |i|
    left  = x[i] - x[i-1]
    right = x[i+1] - x[i]
    a[i] = left
    b[i] = 2.0 * (left + right)
    c[i] = right
    d[i] = 6.0 * ((y[i+1] - y[i]) / right - (y[i] - y[i-1]) / left)
  }

  case ends
  when nil                                      # natural: S'' = 0 at both ends
    first_row, last_row = 0, n-1
    b[0] = 1.0 ; c[0] = 0.0 ; d[0] = 0.0
    a[n-1] = 0.0 ; b[n-1] = 1.0 ; d[n-1] = 0.0
  when :not_a_knot                              # not-a-knot: S''' continuous at x[1], x[n-2]
    raise ArgumentError, "not-a-knot needs at least 4 points, got #{n}" if n < 4
    first_row, last_row = 1, n-2
    h0 = x[1] - x[0] ; h1 = x[2] - x[1]         # d[1] and d[n-2] are the interior
    b[1] = 3.0 * h0 + 2.0 * h1 + h0 * h0 / h1   # right-hand sides already
    c[1] = (h1 * h1 - h0 * h0) / h1
    hm = x[n-2] - x[n-3] ; hn = x[n-1] - x[n-2]
    a[n-2] = (hm * hm - hn * hn) / hm
    b[n-2] = 2.0 * hm + 3.0 * hn + hn * hn / hm
  else                                          # clamped: S' given at both ends
    first_row, last_row = 0, n-1
    first, last = ends
    h0 = x[1] - x[0]
    b[0] = 2.0 * h0 ; c[0] = h0
    d[0] = 6.0 * ((y[1] - y[0]) / h0 - first)
    hn = x[n-1] - x[n-2]
    a[n-1] = hn ; b[n-1] = 2.0 * hn
    d[n-1] = 6.0 * (last - (y[n-1] - y[n-2]) / hn)
  end

  cc[first_row] = c[first_row] / b[first_row]   # Thomas, forward
  dd[first_row] = d[first_row] / b[first_row]
  CArray.jit_for((first_row+1)..last_row) { |i|
    denominator = b[i] - a[i] * cc[i-1]
    cc[i] = c[i] / denominator
    dd[i] = (d[i] - a[i] * dd[i-1]) / denominator
  }

  moment[last_row] = dd[last_row]               # Thomas, back substitution
  CArray.jit_for((last_row-1).step(first_row, -1)) { |i|
    moment[i] = dd[i] - cc[i] * moment[i+1]
  }

  if ends == :not_a_knot                        # the rows that were left out
    moment[0]   = moment[1] - (x[1] - x[0]) * (moment[2] - moment[1]) / (x[2] - x[1])
    moment[n-1] = moment[n-2] + (x[n-1] - x[n-2]) * (moment[n-2] - moment[n-3]) / (x[n-2] - x[n-3])
  end
  moment
end

# Evaluate at arbitrary points.  The knots are not equally spaced, so each
# query point has to find its interval; `passes` bounds the bisection, and a
# kernel that cannot fail to stop is the better kind.
def evaluate (x, y, moment, n, query, value, derivative)
  points = query.dim[0]
  passes = Math.log2(n).ceil + 1

  CArray.jit_for(points) { |k|
    lo = 0
    hi = n - 2
    (0...passes).each { |pass|
      break if lo >= hi
      middle = (lo + hi + 1) / 2
      if x[middle] <= query[k]
        lo = middle
      else
        hi = middle - 1
      end
    }
    h = x[lo+1] - x[lo]
    t = query[k] - x[lo]
    linear = (y[lo+1] - y[lo]) / h - h * (2.0 * moment[lo] + moment[lo+1]) / 6.0
    cubic = (moment[lo+1] - moment[lo]) / (6.0 * h)
    value[k] = y[lo] + t * (linear + t * (0.5 * moment[lo] + t * cubic))
    derivative[k] = linear + t * (moment[lo] + t * 3.0 * cubic)
  }
end

# The same evaluation where the query points are sorted.  Then nothing has to
# search: the interval only moves forward, so one sweep carries it from cell to
# cell and passes each knot once -- O(m + n) against O(m log n).  How far it
# advances at one cell is the data's business, which is what `while` is for;
# there is no bound to put in an extent.
#
# The first cell has no k-1 to read, so it is seeded here and the sweep starts
# at 1 -- `jit_for(points)` over a body reading interval[k-1] is refused, and
# says so, exactly as the Thomas sweeps above are stated from 1.
#
# The intervals are found first and evaluated second, which is what keeps the
# seed from needing a copy of the polynomial: it is one entry in `interval`,
# and the second kernel does every point the same way.  Fusing the two into a
# single kernel is worth about 30% more, at that price.
def resample (x, y, moment, n, query, value, derivative, interval)
  points = query.dim[0]

  seed = 0
  seed += 1 while seed < n - 2 && x[seed+1] <= query[0]
  interval[0] = seed

  CArray.jit_for(1...points) { |k|
    lo = interval[k-1]
    while lo < n - 2 && x[lo+1] <= query[k]
      lo = lo + 1
    end
    interval[k] = lo
  }

  CArray.jit_for(points) { |k|
    lo = interval[k]
    h = x[lo+1] - x[lo]
    t = query[k] - x[lo]
    linear = (y[lo+1] - y[lo]) / h - h * (2.0 * moment[lo] + moment[lo+1]) / 6.0
    cubic = (moment[lo+1] - moment[lo]) / (6.0 * h)
    value[k] = y[lo] + t * (linear + t * (0.5 * moment[lo] + t * cubic))
    derivative[k] = linear + t * (moment[lo] + t * 3.0 * cubic)
  }
end

# ------------------------------------------------------------------ the fit

n = 15
random = Random.new(20260909)
# Knots that are not equally spaced -- measurements rarely are, and nothing
# above assumed they would be.
x = CArray.double(n) { |i| 6.0 * i / (n - 1) }
(1...(n-1)).each { |i| x[i] += random.rand(-0.12..0.12) }
y = CArray.double(n) { |i| curve(x[i]) }

work = Array.new(7) { CArray.double(n) }
natural = moments(x, y, n, work, nil).copy
clamped = moments(x, y, n, work, [slope(x[0]), slope(x[n-1])]).copy
not_a_knot = moments(x, y, n, work, :not_a_knot).copy

points = 601
query = CArray.double(points) { |k| x[0] + (x[n-1] - x[0]) * k / (points - 1) }
truth = CArray.double(points) { |k| curve(query[k]) }

value = CArray.double(points)
derivative = CArray.double(points)

puts "cubic spline through #{n} unevenly spaced points, sampled at #{points}"

results = {}
{ "natural" => natural, "clamped" => clamped, "not-a-knot" => not_a_knot }.each do |name, moment|
  evaluate(x, y, moment, n, query, value, derivative)
  results[name] = [value.copy, derivative.copy]

  error = (value - truth).abs
  edge = x[1] - x[0]                     # the first and last interval
  ends = (0...points).select { |k| query[k] < x[0] + edge || query[k] > x[n-1] - edge }
  inside = (0...points).to_a - ends

  puts format("  %-10s  max error %.2e overall, %.2e in the end intervals, %.2e inside",
              name, error.max, ends.map { |k| error[k] }.max, inside.map { |k| error[k] }.max)
end

# What each boundary condition asked for, checked at the ends.
puts format("  natural   S''(a) = %.1e, S''(b) = %.1e -- zero, by construction",
            natural[0], natural[n-1])
puts format("  clamped   S'(a)  = %+.6f vs %+.6f asked for", results["clamped"][1][0], slope(x[0]))
puts format("            S'(b)  = %+.6f vs %+.6f", results["clamped"][1][points-1], slope(x[n-1]))
jump = lambda { |m, i, j, k|                   # S''' across the knot that is not one
  (m[j] - m[i]) / (x[j] - x[i]) - (m[k] - m[j]) / (x[k] - x[j])
}
puts format("  not-knot  S''' jumps by %.1e at x[1] and %.1e at x[n-2] -- neither is a knot",
            jump.call(not_a_knot, 0, 1, 2), jump.call(not_a_knot, n-3, n-2, n-1))

# The interpolation itself: all of them pass through every knot, so all three
# are asked, not just the one whose name comes first.
knots = CArray.double(n) { |i| x[i] }
at_knots = CArray.double(n)
at_knots_slope = CArray.double(n)
{ "natural" => natural, "clamped" => clamped, "not-a-knot" => not_a_knot }.each do |name, moment|
  evaluate(x, y, moment, n, knots, at_knots, at_knots_slope)
  puts format("  %-10s max |S(x_i) - y_i| = %.2e", name, (at_knots - y).abs.max)
end

# The query grid above is sorted, so the sweep applies to it -- and gives back
# the same doubles, not merely close ones: the interval a point lands in is the
# same interval, and the polynomial evaluated in it is the same expression.
swept = CArray.double(points)
swept_slope = CArray.double(points)
resample(x, y, clamped, n, query, swept, swept_slope, CArray.int32(points))
puts "  the sorted sweep agrees bit for bit  #{swept.to_a == results["clamped"][0].to_a}"

# The curve, and the samples it was built from.
rows, columns = 15, 74
low, high = -0.55, 0.85
canvas = Array.new(rows) { " " * columns }
plot = lambda { |xs, ys, mark|
  xs.each_with_index do |xv, k|
    column = ((xv - x[0]) / (x[n-1] - x[0]) * (columns - 1)).round
    row = ((high - ys[k]) / (high - low) * (rows - 1)).round
    canvas[row][column] = mark if row.between?(0, rows - 1) && column.between?(0, columns - 1)
  end
}
plot.call(query.to_a, results["clamped"][0].to_a, ".")
plot.call(x.to_a, y.to_a, "o")
puts
canvas.each { |row| puts "  |#{row}|" }
puts "  o samples, . the clamped spline through them"

# ------------------------------------------------------------------- the cost

def time (repeats)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

# The same two kernels written as Ruby loops.  The fit is O(n) and the
# evaluation O(m log n), so both grow slowly -- what the compiled version
# removes is the per-element cost, which is where all of the difference is.
def ruby_moments (x, y, n, work)
  a, b, c, d, cc, dd, moment = work
  (1...(n-1)).each do |i|
    left  = x[i] - x[i-1]
    right = x[i+1] - x[i]
    a[i] = left
    b[i] = 2.0 * (left + right)
    c[i] = right
    d[i] = 6.0 * ((y[i+1] - y[i]) / right - (y[i] - y[i-1]) / left)
  end
  b[0] = 1.0 ; c[0] = 0.0 ; d[0] = 0.0
  a[n-1] = 0.0 ; b[n-1] = 1.0 ; d[n-1] = 0.0
  cc[0] = c[0] / b[0]
  dd[0] = d[0] / b[0]
  (1...n).each do |i|
    denominator = b[i] - a[i] * cc[i-1]
    cc[i] = c[i] / denominator
    dd[i] = (d[i] - a[i] * dd[i-1]) / denominator
  end
  moment[n-1] = dd[n-1]
  (n-2).step(0, -1) do |i|
    moment[i] = dd[i] - cc[i] * moment[i+1]
  end
  moment
end

def ruby_evaluate (x, y, moment, n, query, value, derivative)
  query.dim[0].times do |k|
    lo, hi = 0, n - 2
    while lo < hi
      middle = (lo + hi + 1) / 2
      if x[middle] <= query[k] then lo = middle else hi = middle - 1 end
    end
    h = x[lo+1] - x[lo]
    t = query[k] - x[lo]
    linear = (y[lo+1] - y[lo]) / h - h * (2.0 * moment[lo] + moment[lo+1]) / 6.0
    cubic = (moment[lo+1] - moment[lo]) / (6.0 * h)
    value[k] = y[lo] + t * (linear + t * (0.5 * moment[lo] + t * cubic))
    derivative[k] = linear + t * (moment[lo] + t * 3.0 * cubic)
  end
end

puts
[[200, 20_000], [2_000, 200_000]].each do |size, sampled|
  knots = CArray.double(size) { |i| 6.0 * i / (size - 1) }
  values = CArray.double(size) { |i| curve(knots[i]) }
  scratch = Array.new(7) { CArray.double(size) }
  at = CArray.double(sampled) { |k| 6.0 * k / (sampled - 1) }
  out, slopes = CArray.double(sampled), CArray.double(sampled)

  fit = time(20) { moments(knots, values, size, scratch, nil) }
  fit_ruby = time(3) { ruby_moments(knots, values, size, scratch) }
  moment = moments(knots, values, size, scratch, nil)
  sample = time(5) { evaluate(knots, values, moment, size, at, out, slopes) }
  sample_ruby = time(2) { ruby_evaluate(knots, values, moment, size, at, out, slopes) }
  cells = CArray.int32(sampled)
  swept = time(5) { resample(knots, values, moment, size, at, out, slopes, cells) }

  puts format("  n = %5d   fit %7.1f us vs %8.1f us Ruby (%3.0fx)", size, fit * 1e6, fit_ruby * 1e6, fit_ruby / fit)
  puts format("  m = %6d  eval %7.1f us vs %8.1f us Ruby (%3.0fx)", sampled, sample * 1e6, sample_ruby * 1e6, sample_ruby / sample)
  puts format("             sorted %7.1f us -- the same points, with the search taken out (%.1fx)",
              swept * 1e6, sample / swept)
end
