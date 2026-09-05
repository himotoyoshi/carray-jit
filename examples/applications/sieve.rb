# The sieve of Eratosthenes.
#
# Each prime crosses out its own multiples, and how many that is depends on
# the prime: the inner loop's length is different for every cell and is not
# knowable before the loop runs, which is what `while` is for.  The cells it
# writes are at computed subscripts, and they are cells this same loop will
# later read -- crossing out 2's multiples is what makes 4 composite before
# the loop reaches it.
#
# Written over whole arrays this is a pass per prime, each one building an
# index array to scatter through.  Written here it is the sieve as it is
# stated.
#
#   ruby examples/applications/sieve.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

N = 1_000_000

def sieve (n)
  flags = CArray.int8(n).fill(1)
  flags[0] = 0
  flags[1] = 0
  CArray.jit_for(2...n) { |i|
    if flags[i] == 1
      j = i * i                   # everything smaller was crossed out already
      while j < n
        flags[j] = 0
        j = j + i
      end
    end
  }
  flags
end

flags = sieve(N)
primes = flags.eq(1).count(1)

puts "primes below #{N}"
puts "  how many                  #{primes}"
puts "  the first few             #{(0...30).select { |i| flags[i] == 1 }.inspect}"
puts "  the largest               #{(0...N).reverse_each.find { |i| flags[i] == 1 }}"

# The inner loop cannot be written as an extent here.  `(i*i...n).step(i)` is
# refused, and so is any inner range whose bounds a cell works out: an inner
# loop runs over an integer expression in literals and captured scalars, so
# that the kernel knows its shape before it runs.  `while` is the spelling
# that carries the bound the data decides.
begin
  counts = CArray.int32(N)
  CArray.jit_for(2...N) { |i|
    seen = 0
    (i...N).each { |j| seen = seen + 1 }
    counts[i] = seen
  }
rescue CArray::JIT::Unsupported => error
  puts "  a per-cell inner range    refused: #{error.message.sub(/ \(at line.*/m, "")}"
end

# The same sieve in Ruby, for the answer and the time.
def sieve_in_ruby (n)
  flags = Array.new(n, 1)
  flags[0] = 0
  flags[1] = 0
  i = 2
  while i < n
    if flags[i] == 1
      j = i * i
      while j < n
        flags[j] = 0
        j = j + i
      end
    end
    i = i + 1
  end
  flags
end

in_ruby = sieve_in_ruby(N)
puts "  agrees with Ruby          #{flags.to_a == in_ruby}"

sieve(N)                                # compiled and cached on the first call

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
5.times { sieve(N) }
compiled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 5

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sieve_in_ruby(N)
interpreted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts
puts format("one sieve to %d: %.1f ms compiled, %.1f ms in Ruby (%.0fx)",
            N, compiled * 1e3, interpreted * 1e3, interpreted / compiled)
