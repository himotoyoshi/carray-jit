# The Mandelbrot set, as an escape-time count.
#
# Every cell iterates z = z*z + c until |z| passes 2, and how many passes that
# took is what is drawn.  The number of passes is different for every cell and
# is not known before the loop runs, which is what `while` is for; the bail-out
# count is a cap on it, so this is written as an inner loop with a `break`,
# and the same thing with `while` is measured beside it.
#
# Written over whole arrays this would be one pass per iteration over the
# entire plane, with every cell paying for the deepest one.  Here each cell
# stops when it escapes.
#
# Three spellings of the same set are here: the bounded inner loop, the same
# thing with `while`, and the iteration written in one variable with a Complex
# local, which is what z = z*z + c says.
#
#   ruby examples/applications/mandelbrot.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

ROWS, COLUMNS = 36, 96
LIMIT = 500

# The window on the plane: the whole set, squashed to fit a terminal.
x0, x1 = -2.2, 0.8
y0, y1 = -1.25, 1.25

counts = CArray.int32(ROWS, COLUMNS)

escape = lambda do
  CArray.jit_for(ROWS, COLUMNS) { |i, j|
    cx = x0 + (x1 - x0) * j / (COLUMNS - 1.0)
    cy = y0 + (y1 - y0) * i / (ROWS - 1.0)
    zx = 0.0
    zy = 0.0
    taken = 0
    (0...LIMIT).each { |k|
      break if zx * zx + zy * zy > 4.0
      next_zx = zx * zx - zy * zy + cx      # a kernel assigns one name at a time
      zy = 2.0 * zx * zy + cy
      zx = next_zx
      taken = taken + 1
    }
    counts[i, j] = taken
  }
end

escape.call

# LIMIT passes without escaping is taken for a point of the set.
SHADES = " .:-=+*#%"
puts "the set, by escape time"
counts.to_a.each do |row|
  puts "  " + row.map { |count|
    next "@" if count == LIMIT
    step = Math.log(count + 1) / Math.log(LIMIT + 1) * SHADES.size
    SHADES[[step.to_i, SHADES.size - 1].min]
  }.join
end

inside = counts.eq(LIMIT).count(1)
puts format("  %d of %d cells never escaped", inside, ROWS * COLUMNS)

# The same iteration written with `while`, which is what it would be if there
# were no cap to put in an extent.  It gives the same counts; what it gives up
# is the guarantee that the loop ends, which here is exactly what the cap was
# providing -- a cell inside the set does not escape, ever, so the `while`
# needs the count in its condition to stop at all.
by_while = CArray.int32(ROWS, COLUMNS)
CArray.jit_for(ROWS, COLUMNS) { |i, j|
  cx = x0 + (x1 - x0) * j / (COLUMNS - 1.0)
  cy = y0 + (y1 - y0) * i / (ROWS - 1.0)
  zx = 0.0
  zy = 0.0
  taken = 0
  while zx * zx + zy * zy <= 4.0 && taken < LIMIT
    next_zx = zx * zx - zy * zy + cx
    zy = 2.0 * zx * zy + cy
    zx = next_zx
    taken = taken + 1
  end
  by_while[i, j] = taken
}
puts "  while agrees with the bounded loop: #{by_while.to_a == counts.to_a}"

# ------------------------------------------------------- and in one variable

# The iteration is z = z*z + c, and a kernel can say that.  A Complex local
# is a `double _Complex` in the generated C, so the two reals above collapse
# into one name and the temporary they needed goes away -- `z = z * z + c` is
# a single assignment, and multiplication is the one Ruby's Complex does.
#
# `Complex(x, y)` is the way in from two reals, `abs` one of the ways back
# out.  Ordering is refused on a Complex, as Ruby refuses it, so the test is
# on `abs` -- and `abs > 2.0` is the same test as `zx*zx + zy*zy > 4.0`, a
# square root apart.
complex_counts = CArray.int32(ROWS, COLUMNS)

complex_escape = lambda do
  CArray.jit_for(ROWS, COLUMNS) { |i, j|
    c = Complex(x0 + (x1 - x0) * j / (COLUMNS - 1.0),
                y0 + (y1 - y0) * i / (ROWS - 1.0))
    z = Complex(0.0, 0.0)
    taken = 0
    (0...LIMIT).each { |k|
      break if z.abs > 2.0
      z = z * z + c
      taken = taken + 1
    }
    complex_counts[i, j] = taken
  }
end

complex_escape.call
puts "  the Complex spelling agrees:        #{complex_counts.to_a == counts.to_a}"

# It costs a square root the real spelling did not pay -- `abs` is `cabs`,
# where the two reals compared a sum of squares against four -- and the frame
# below says how much that is, which on this machine is nothing worth
# choosing between.  A kernel that wanted the other test back would write
# `(z * z.conjugate).real > 4.0`: the same arithmetic, in one name.
complex_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
10.times { complex_escape.call }
complex_timed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - complex_started) / 10

# What it would have cost in Ruby.
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
10.times { escape.call }
compiled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 10

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
(0...ROWS).each do |i|
  (0...COLUMNS).each do |j|
    cx = x0 + (x1 - x0) * j / (COLUMNS - 1.0)
    cy = y0 + (y1 - y0) * i / (ROWS - 1.0)
    zx = zy = 0.0
    taken = 0
    LIMIT.times do
      break if zx * zx + zy * zy > 4.0
      zx, zy = zx * zx - zy * zy + cx, 2.0 * zx * zy + cy
      taken += 1
    end
    by_while[i, j] = taken
  end
end
interpreted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts format("  one frame: %.2f ms compiled, %.2f ms as a Complex, %.2f ms in Ruby (%.0fx)",
            compiled * 1e3, complex_timed * 1e3, interpreted * 1e3,
            interpreted / compiled)
