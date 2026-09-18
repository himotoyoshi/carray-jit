# Collatz: how long each number takes to fall to 1.
#
# Halve it when it is even, take 3n+1 when it is odd, and count the steps
# until it reaches 1.  How many steps that is depends on the number, and
# nothing about the number says in advance -- 3 takes 7 steps and 27 takes
# 111 -- so the length of the loop is the cell's own business and is what
# `while` is for.
#
# Written over whole arrays this is a pass per step over everything still
# running, and every cell pays for the longest one; there is no expression
# that lets one cell stop.  Here each cell stops when it reaches 1, and the
# two answers -- the step count and the highest value on the way -- are
# written in the same pass.
#
#   ruby examples/applications/collatz.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

N = 1_000_000

def collatz (n)
  steps = CArray.int32(n)
  peak  = CArray.int64(n)
  kernel = CArray.jit_for(1...n) { |i|
    x = i
    hi = x
    count = 0
    while x != 1
      x = x % 2 == 0 ? x / 2 : 3 * x + 1
      hi = x if x > hi
      count = count + 1
    end
    steps[i] = count
    peak[i] = hi
  }
  [steps, peak, kernel]
end

steps, peak, kernel = collatz(N)

# The numbers that took longer than anything before them.
puts "record holders below #{N}"
record = 0
(1...N).each do |i|
  next unless steps[i] > record
  record = steps[i]
  next unless record > 400
  puts format("  %7d  %3d steps, reaching %d", i, record, peak[i])
end
puts format("  the highest value reached by any of them is %d, from %d",
            peak.max, peak.max_addr)

# `x` is an int64 in the generated C, and nothing here asked for that.  A
# local's type is settled from the whole body: `hi` is what `peak` is given,
# `peak` is an int64 array, and `hi = x` carries that back to `x`.  Which is
# why 704511 reaches 56 billion without overflowing an int32 on the way.
puts
puts "what the local was compiled as"
puts format("  %s", kernel.c_source.lines.grep(/^\s*int\d+_t x =/).first.strip)

# The same walk in Ruby, for the answer and the time.  Over the first tenth,
# because the point of the comparison is the ratio.
CHECK = N / 10

def collatz_in_ruby (n)
  steps = Array.new(n, 0)
  (1...n).each do |i|
    x = i
    count = 0
    while x != 1
      x = x.even? ? x / 2 : 3 * x + 1
      count += 1
    end
    steps[i] = count
  end
  steps
end

in_ruby = collatz_in_ruby(CHECK)
puts
puts format("agrees with Ruby over 1...%d  %s",
            CHECK, steps[0...CHECK].to_a == in_ruby)

collatz(CHECK)                          # compiled and cached on the first call

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
5.times { collatz(CHECK) }
compiled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 5

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
collatz_in_ruby(CHECK)
interpreted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts format("%d starting values: %.0f ms compiled, %.0f ms in Ruby (%.0fx)",
            CHECK, compiled * 1e3, interpreted * 1e3, interpreted / compiled)

# And the loop the kernel runs is the one the block states: `x.even?` is not
# in the subset, so the parity test is written as the arithmetic it is.
begin
  CArray.jit_for(1) { |i| steps[i] = i.even? ? 0 : 1 }
rescue CArray::JIT::Unsupported => error
  puts
  puts "refused: #{error.message.sub(/ \(at line.*/m, "")}"
end
