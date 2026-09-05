# One element-wise expression, four ways.
#
# CArray already avoids the intermediate arrays: CArray.fuse streams the
# expression so `b * c` never becomes a whole array of its own.  Walked by
# CArray, what it does not do is turn the expression into a per-cell
# computation -- each operation is still its own pass over the data.
#
# Which is why fuse is measured twice here.  Requiring this gem registers it
# as CArray's expression evaluator, so `CArray.fuse` over an array this size
# is compiled rather than walked, and the walk is what CArray does where the
# gem is not installed.  Reporting one number for both would say the wrong
# thing about whichever of them was not running.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "carray/jit"

N = 4_000_000
SAMPLES = 5

def median (list) = list.sort[list.size / 2]

a = CArray.double(N).seq!
b = CArray.double(N).seq!(10)
c = CArray.double(N).seq!(100)
out = CArray.double(N)

def timed (samples)
  median(samples.times.map { Benchmark.realtime { yield } })
end

# The evaluator this gem registered, put back afterwards: what is being
# measured is the difference between having it and not.
JIT_EVALUATOR = CArray.expression_evaluator

def walked (samples)
  CArray.expression_evaluator = nil
  timed(samples) { yield }
ensure
  CArray.expression_evaluator = JIT_EVALUATOR
end

CArray.jit_each { out = a + b * c }          # warm the kernel cache

plain  = timed(SAMPLES) { a + b * c }
walk   = walked(SAMPLES) { CArray.fuse { a + b * c }.to_ca }
fused  = timed(SAMPLES) { CArray.fuse { a + b * c }.to_ca }
kernel = timed(SAMPLES) { CArray.jit_each { out = a + b * c } }

reference = a + b * c
difference = (0...N).step(9973).map { |i| (out[i] - reference[i]).abs }.max

puts "n = #{N},  out = a + b * c"
puts format("a + b * c                    %8.1f ms   %5.2f ns/element",
            plain * 1e3, plain / N * 1e9)
puts format("CArray.fuse, walked          %8.1f ms   %5.2f ns/element   %.2fx",
            walk * 1e3, walk / N * 1e9, plain / walk)
puts format("CArray.fuse, compiled here   %8.1f ms   %5.2f ns/element   %.2fx",
            fused * 1e3, fused / N * 1e9, plain / fused)
puts format("jit_each { out = ... }       %8.1f ms   %5.2f ns/element   %.2fx",
            kernel * 1e3, kernel / N * 1e9, plain / kernel)
puts format("largest difference: %.3g", difference)

puts
puts "A longer expression, where the number of passes tells:"
long_plain = timed(SAMPLES) { (a + b) * (c - a) + b * c - a }
long_walk = walked(SAMPLES) {
  CArray.fuse { (a + b) * (c - a) + b * c - a }.to_ca
}
long_fused = timed(SAMPLES) {
  CArray.fuse { (a + b) * (c - a) + b * c - a }.to_ca
}
CArray.jit_each { out = (a + b) * (c - a) + b * c - a }
long_kernel = timed(SAMPLES) {
  CArray.jit_each { out = (a + b) * (c - a) + b * c - a }
}
puts format("plain                        %8.1f ms   %5.2f ns/element",
            long_plain * 1e3, long_plain / N * 1e9)
puts format("CArray.fuse, walked          %8.1f ms   %5.2f ns/element   %.2fx",
            long_walk * 1e3, long_walk / N * 1e9, long_plain / long_walk)
puts format("CArray.fuse, compiled here   %8.1f ms   %5.2f ns/element   %.2fx",
            long_fused * 1e3, long_fused / N * 1e9, long_plain / long_fused)
puts format("jit_each { out = ... }       %8.1f ms   %5.2f ns/element   %.2fx",
            long_kernel * 1e3, long_kernel / N * 1e9, long_plain / long_kernel)

# Memory is the other axis, and it does not follow the times.  Measured
# separately, because a peak is a property of a process rather than of a
# block: `benchmark/footprint.rb` runs each way in a process of its own and
# reports the high-water mark.
puts
puts "for the memory each way holds, run benchmark/footprint.rb"
