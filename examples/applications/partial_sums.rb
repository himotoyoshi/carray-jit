# Nine series summed in one pass -- the "partial sums" benchmark, as it is
# written for an interpreter: one loop over d = 1..n, nine accumulators, and
# no array anywhere in it.
#
# A kernel can be that program.  The accumulators are CScalars, which are the
# one-cell arrays they subclass, and every iteration writing the one cell they
# have is what makes an accumulator without asking for one.
#
# And the answers are the Ruby loop's, bit for bit, with nothing asked for:
# the kernel's own loop over its extents is taken in the order the extents
# say.  What may be split into partial sums -- the name of this file -- is an
# *inner* loop, the reduction a cell does for itself, and the second half of
# this program is the same harmonic sum written that way, where the order does
# become a choice.
#
#   ruby examples/applications/partial_sums.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

N = 500_000

def accumulators
  Array.new(9) { CScalar.double() { 0.0 } }
end

def sum_series (n)
  s0, s1, s2, s3, s4, s5, s6, s7, s8 = accumulators
  CArray.jit_for(1..n) { |k|
    d = k * 1.0
    d2 = d * d
    d3 = d2 * d
    ds = Math.sin(d)
    dc = Math.cos(d)
    # The alternating sign is written from the index rather than carried in a
    # variable: `alt = -alt` would be a chain from one iteration to the next,
    # and this is the same sequence with no chain in it.
    alt = k % 2 == 1 ? 1.0 : -1.0

    s0[] = s0[] + (2.0 / 3.0) ** (d - 1.0)      # a geometric series
    s1[] = s1[] + 1.0 / Math.sqrt(d)            # zeta(1/2), which diverges
    s2[] = s2[] + 1.0 / (d * (d + 1.0))         # telescoping, to 1
    s3[] = s3[] + 1.0 / (d3 * ds * ds)          # Flint Hills
    s4[] = s4[] + 1.0 / (d3 * dc * dc)          # Cookson Hills
    s5[] = s5[] + 1.0 / d                       # harmonic
    s6[] = s6[] + 1.0 / d2                      # zeta(2)
    s7[] = s7[] + alt / d                       # alternating harmonic
    s8[] = s8[] + alt / (2.0 * d - 1.0)         # Gregory's series
  }
  [s0, s1, s2, s3, s4, s5, s6, s7, s8].map { |s| s[0] }
end

def sum_series_in_ruby (n)
  s0 = s1 = s2 = s3 = s4 = s5 = s6 = s7 = s8 = 0.0
  d_int = 1
  while d_int <= n
    d = d_int.to_f
    d2 = d * d
    d3 = d2 * d
    ds = Math.sin(d)
    dc = Math.cos(d)
    alt = d_int % 2 == 1 ? 1.0 : -1.0
    s0 = s0 + (2.0 / 3.0) ** (d - 1.0)
    s1 = s1 + 1.0 / Math.sqrt(d)
    s2 = s2 + 1.0 / (d * (d + 1.0))
    s3 = s3 + 1.0 / (d3 * ds * ds)
    s4 = s4 + 1.0 / (d3 * dc * dc)
    s5 = s5 + 1.0 / d
    s6 = s6 + 1.0 / d2
    s7 = s7 + alt / d
    s8 = s8 + alt / (2.0 * d - 1.0)
    d_int = d_int + 1
  end
  [s0, s1, s2, s3, s4, s5, s6, s7, s8]
end

NAMES = ["(2/3)^(d-1)", "1/sqrt(d)", "1/(d(d+1))", "1/(d^3 sin^2 d)",
         "1/(d^3 cos^2 d)", "1/d", "1/d^2", "(-1)^(d-1)/d",
         "(-1)^(d-1)/(2d-1)"]

sums = sum_series(N)
in_ruby = sum_series_in_ruby(N)

puts "nine series to d = #{N}"
NAMES.each_with_index do |name, i|
  puts format("  %-18s %19.13f   %s Ruby's",
              name, sums[i], sums[i] == in_ruby[i] ? "==" : "!=")
end

# The telescoping sum has an exact answer to be judged against, which is
# 1 - 1/(n+1).
telescoped = 1.0 - 1.0 / (N + 1.0)
puts
puts format("  the telescoping sum is off by %.1e", (sums[2] - telescoped).abs)
puts format("  every one of the nine matches the Ruby loop bit for bit: %s",
            sums == in_ruby)

# ------------------------------------------------------- where the order is a choice

# The harmonic sum again, with the loop written inside the cell instead of
# being the kernel's own.  That is a reduction, and a reduction's accumulator
# may be split into partial sums: `reassociate: false` asks for the serial
# order, and the default asks for the faster one, which by splitting the
# accumulation is also what limits the cancellation.
def harmonic (n, reassociate)
  out = CScalar.double() { 0.0 }
  CArray.jit_for(1, reassociate: reassociate) { |c|
    total = 0.0
    (1..n).each { |k| total = total + 1.0 / (k * 1.0) }
    out[] = total
  }
  out[0]
end

split = harmonic(N, true)
serial = harmonic(N, false)
by_carray = (1.0 / CArray.double(N).seq!(1.0)).sum

puts
puts "the harmonic sum as an inner loop"
puts format("  split into partial sums   %.15f", split)
puts format("  the serial order          %.15f", serial)
puts format("  serial == the outer loop above and Ruby's: %s", serial == sums[5])
puts format("  split == CArray's own sum:                 %s", split == by_carray)

# And what the pass costs each way.
sum_series(N)                          # compiled and cached on the first call

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
3.times { sum_series(N) }
compiled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 3

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sum_series_in_ruby(N)
interpreted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts
puts format("one pass over %d terms", N)
puts format("  compiled                       %6.1f ms", compiled * 1e3)
puts format("  the same loop in Ruby          %6.1f ms (%.0fx)",
            interpreted * 1e3, interpreted / compiled)
