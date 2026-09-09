# What one call to a compiled kernel costs before any cell is touched.
#
# break_even.rb measures compiling, which happens once.  This measures the
# other fixed cost, which does not: every `jit_for` decides which kernel the
# block wants, checks that the operands are the shape it was compiled for and
# that no cell it would touch is outside them, and packs the pointers, strides
# and bounds the C takes.  None of that depends on how many cells the call
# then runs over, so it is what the answer to "one kernel or several?" turns
# on -- and it is per operand as much as per call.
#
# Kernels are warmed before timing, so nothing here includes compiling.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "carray/jit"

CALLS = 20_000
SAMPLES = 5

def median (list) = list.sort[list.size / 2]

def per_call (repeats = CALLS)
  2.times { repeats.times { yield } }         # warm the kernel and the caches
  median(SAMPLES.times.map {
    Benchmark.realtime { repeats.times { yield } } / repeats
  })
end

# Two cells, and a body that runs over one of them: the smallest call there
# is, so what it measures is the call rather than the arithmetic.
a, b, c, d, cc, dd = Array.new(6) { CArray.double(2) }

bodies = {
  2 => proc { CArray.jit_for(1...2) { |i| c[i] = a[i] } },
  3 => proc { CArray.jit_for(1...2) { |i| c[i] = a[i] + b[i] } },
  4 => proc { CArray.jit_for(1...2) { |i| d[i] = a[i] + b[i] * c[i] } },
  6 => proc { CArray.jit_for(1...2) { |i|
         denominator = b[i] - a[i] * cc[i-1]
         cc[i] = c[i] / denominator
         dd[i] = (d[i] - a[i] * dd[i-1]) / denominator
       } },
}

puts "one call, one cell"
costs = bodies.transform_values { |body| per_call(&body) }
costs.each do |operands, cost|
  puts format("  %d arrays              %6.2f us", operands, cost * 1e6)
end

# A straight line through the four, since that is what they are: a fixed part
# per call and a part that repeats per operand.
xs = costs.keys.map(&:to_f)
ys = costs.values
mean_x = xs.sum / xs.size
mean_y = ys.sum / ys.size
slope = xs.zip(ys).sum { |x, y| (x - mean_x) * (y - mean_y) } /
        xs.sum { |x| (x - mean_x) ** 2 }
fixed = mean_y - slope * mean_x
puts format("  so: %.1f us per call + %.1f us per operand", fixed * 1e6, slope * 1e6)

# Where it goes.  `CompiledKernel#call` is the second half -- the checks and
# the packing -- so the difference is the first: reading the block, deciding
# what its free names are, and finding the kernel already compiled for them.
kernel = bodies[3].call
arrays = { :a => a, :b => b, :c => c }
whole = costs[3]
back = per_call { kernel.call(arrays, {}, [[1, 2, 1]]) }
puts format("  of the 3-array call:  %6.2f us checking and packing (CompiledKernel#call)",
            back * 1e6)
puts format("                        %6.2f us finding which kernel to run",
            (whole - back) * 1e6)

# And what it is against, once there are cells to run over.  The same body at
# a size worth compiling for: the fixed cost is still there and is no longer
# what the call is made of.
puts
puts "the same 6-array sweep, by size"
one = costs[6]
[1, 10, 100, 1_000, 10_000, 100_000].each do |n|
  a, b, c, d, cc, dd = Array.new(6) { CArray.double(n + 1) }
  sweep = proc {
    CArray.jit_for(1...(n+1)) { |i|
      denominator = b[i] - a[i] * cc[i-1]
      cc[i] = c[i] / denominator
      dd[i] = (d[i] - a[i] * dd[i-1]) / denominator
    }
  }
  cost = per_call([CALLS / [n / 10, 1].max, 20].max, &sweep)
  puts format("  n = %6d           %8.2f us   %5.1f%% of it the call itself",
              n, cost * 1e6, one / cost * 100)
end
