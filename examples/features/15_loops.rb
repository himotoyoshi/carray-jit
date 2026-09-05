# Loops inside a kernel: an inner `each` with a `break`, and `while` where the
# bound is not knowable.
#
# The kernel's own loop is written by the extents.  Inside the body a cell may
# still need a loop of its own -- a search, an iteration to a tolerance -- and
# there are two spellings, which differ in whether the number of passes can be
# bounded before the loop runs.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

rows, columns = 5, 8
source = CArray.double(rows, columns) { |i, j| (j - i) * 1.0 }
threshold = 1.5

# A search: the first column past the threshold, or -1.  `break` in an inner
# loop means what it means in Ruby, and so does `next`.
first = CArray.int32(rows)
CArray.jit_for(rows) { |i|
  found = -1
  (0...columns).each { |j|
    if source[i, j] > threshold
      found = j
      break
    end
  }
  first[i] = found
}

reference = (0...rows).map { |i|
  (0...columns).find { |j| source[i, j] > threshold } || -1
}

puts "an inner loop with a break"
puts "  first past #{threshold}         #{first.to_a.inspect}"
puts "  matches Ruby           #{first.to_a == reference}"

# ------------------------------------------------------- a bounded iteration

# Newton's method for a square root, with the bound in the extent.  This is
# the better spelling wherever a bound exists: the kernel cannot fail to stop,
# and a cell that ran out of passes can be told from one that converged.
n = 2000
a = CArray.double(n).seq!(1.0)
tolerance = 1e-12
cap = 40

root = CArray.double(n)
passes = CArray.int32(n)
CArray.jit_for(n) { |i|
  x = a[i]
  taken = 0
  (0...cap).each { |k|
    break if (x * x - a[i]).abs <= tolerance * a[i]
    x = 0.5 * (x + a[i] / x)
    taken = taken + 1
  }
  root[i] = x
  passes[i] = taken
}

puts
puts "Newton, bounded by the extent"
puts format("  worst relative error   %.1e", ((root ** 2 - a).abs / a).max)
puts "  passes taken           #{passes.min}..#{passes.max}"
puts "  none ran out           #{passes.max < cap}"

# ----------------------------------------------------------------- and while

# Where the bound is not knowable, `while` says so.  The condition is read at
# the top of every pass, as Ruby's is; a local the condition reads has to be a
# local before the loop, since the condition is read before the body is.
by_while = CArray.double(n)
CArray.jit_for(n) { |i|
  guess = a[i]
  while (guess * guess - a[i]).abs > tolerance * a[i]
    guess = 0.5 * (guess + a[i] / guess)
  end
  by_while[i] = guess
}

puts
puts "while"
puts "  same answers           #{by_while.to_a == root.to_a}"

# What it gives up is the guarantee that the loop ends -- nothing here can
# decide that in general, and a kernel that does not return cannot be
# interrupted, because the generated loop has no place to notice a signal.
# The one runaway that can be read off the page is refused rather than
# compiled:
begin
  CArray.jit_for(4) { |i| while true do root[i] = root[i] + 1.0 end }
rescue CArray::JIT::Unsupported => error
  puts "  while true, no break   refused: #{error.message.sub(/ \(at line.*/m, "")}"
end
# `while true` with a `break` in it is an ordinary thing to write, and is left
# alone.  `until` is not in the subset: `while` with the condition negated is
# the same loop, and one spelling is enough to keep.

# ------------------------------------------------------------------- and next

# `next` in the kernel block skips the cell, the way it would end a block Ruby
# was running: the cell keeps its value and its mask, and the loop moves on.
kept = CArray.double(n).fill(-1.0)
CArray.jit_for(n) { |i|
  next if a[i] % 2.0 == 0.0
  kept[i] = a[i]
}
puts
puts "next in the kernel block"
puts "  even cells untouched   #{(0...8).map { |i| kept[i] }.inspect}"

# What it costs: an inner loop carrying a break is not a fold, so it is not
# split into partial sums -- it stays the serial chain it was.  The kernel is
# compiled on its first call and cached, so it is run once before the clock
# starts.
newton = lambda do
  CArray.jit_for(n) { |i|
    x = a[i]
    (0...cap).each { |k|
      break if (x * x - a[i]).abs <= tolerance * a[i]
      x = 0.5 * (x + a[i] / x)
    }
    root[i] = x
  }
end
newton.call

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
20.times { newton.call }
compiled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 20

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
20.times do
  (0...n).each do |i|
    x = a[i]
    cap.times do
      break if (x * x - a[i]).abs <= tolerance * a[i]
      x = 0.5 * (x + a[i] / x)
    end
    root[i] = x
  end
end
interpreted = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 20

puts
puts format("Newton over %d cells: %.3f ms compiled, %.3f ms in Ruby (%.0fx)",
            n, compiled * 1e3, interpreted * 1e3, interpreted / compiled)
