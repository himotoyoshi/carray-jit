# What a narrow array costs, and where the cost is.
#
# A kernel stores in the array's type and computes in `double`, `int64_t` or
# `double _Complex`, so a float32 array is read, widened, worked on two at a
# time, and narrowed again at the store.  The widening is visible in the C:
# this script prints the line, so the numbers below have their reason next to
# them.
#
# Whether the promotion should follow CArray's own rules instead is an open
# question, and this is the mouth to measure it at.  Nothing here needs that
# settled -- these numbers are what today costs, and the same script run
# afterwards is what it cost.
#
# Two sizes, because the answer differs and the difference is the point.  Over
# arrays larger than cache the loop waits for memory, so a narrow type wins by
# moving half the bytes whatever it computes in.  Over arrays that fit, there
# is no traffic to win on and the arithmetic is what is left -- which is where
# computing in float rather than double would tell, and where to look when it
# does.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "carray/jit"

SAMPLES = 9

def median (list) = list.sort[list.size / 2]

# One call of a kernel over a quarter of a million cells is short enough that
# the clock is part of what is measured, so a pass is repeated until it is
# not.  The number reported is still one pass.
def timed (samples, repeats)
  median(samples.times.map {
    Benchmark.realtime { repeats.times { yield } }
  }) / repeats
end

def line (label, seconds, elements, against = nil)
  text = format("  %-22s %8.3f ms  %6.2f ns/element", label, seconds * 1e3,
                seconds / elements * 1e9)
  text += format("   %.2fx", against / seconds) if against
  puts text
end

[["cache-resident", 256 * 1024, 50],
 ["larger than cache", 4_000_000, 5]].each do |where, n, repeats|
  puts "#{where}, n = #{n}"

  a64 = CArray.double(n).seq!(1.0, 1e-3)
  b64 = CArray.double(n).seq!(0.5, 5e-4)
  c64 = CArray.double(n).seq!(2.0, 2e-3)
  o64 = CArray.double(n)

  a32, b32, c32 = a64.float32, b64.float32, c64.float32
  o32 = CArray.float32(n)

  ai = CArray.int32(n).seq!(1)
  bi = CArray.int32(n).seq!(2)
  ci = CArray.int32(n).seq!(3)
  oi = CArray.int32(n)

  CArray.jit_each { o64 = (a64 * b64 + c64) * (a64 - b64) }
  CArray.jit_each { o32 = (a32 * b32 + c32) * (a32 - b32) }
  CArray.jit_each { oi = (ai * bi + ci) * (ai - bi) }

  float64 = timed(SAMPLES, repeats) { CArray.jit_each { o64 = (a64 * b64 + c64) * (a64 - b64) } }
  float32 = timed(SAMPLES, repeats) { CArray.jit_each { o32 = (a32 * b32 + c32) * (a32 - b32) } }
  int32   = timed(SAMPLES, repeats) { CArray.jit_each { oi = (ai * bi + ci) * (ai - bi) } }

  line("float64", float64, n)
  line("float32", float32, n, float64)
  line("int32", int32, n, float64)
  puts
end

# The reason, rather than a claim about it: the float32 kernel's own C.
n = 1024
a32 = CArray.float32(n).seq!(1.0)
b32 = CArray.float32(n).seq!(0.5)
c32 = CArray.float32(n).seq!(2.0)
o32 = CArray.float32(n)
kernel = CArray.jit_each { o32 = (a32 * b32 + c32) * (a32 - b32) }
statement = kernel.c_source.lines.find { |text| text.include?("(float *)(p_o32)") }
puts "the float32 kernel's inner statement:"
puts "  #{statement.strip}"

puts <<~NOTE

  Both types compute in double today, so the ratios above are what moving half
  the bytes bought and nothing else -- which is why the win shrinks as the
  arrays do.  The cache-resident line is the one to watch: with no traffic to
  save, a kernel computing in float would have four lanes where this one has
  two, and the conversions in the statement above would not be there at all.
NOTE
