# Times a compiled per-cell kernel against the same loop written in Ruby.
#
# No threshold is asserted; the point is to see the ratio.  The Ruby loop runs
# on a much shorter array because it is slow enough that matching lengths
# would dominate the run.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "carray/jit"

x = 0.5
jit_length = 1_000_000
ruby_length = 100_000

values = CArray.double(jit_length)
values[0] = 1.0
values[1] = x

# Compile once, so the timing below measures the loop and not the compiler.
compile_time = Benchmark.realtime do
  CArray.jit_for(2...3) { |i|
    w  = x * values[i-1]
    wy = w - values[i-2]
    values[i] = wy + w - wy/i
  }
end

jit_time = Benchmark.realtime do
  CArray.jit_for(2...jit_length) { |i|
    w  = x * values[i-1]
    wy = w - values[i-2]
    values[i] = wy + w - wy/i
  }
end

plain = CArray.double(ruby_length)
plain[0] = 1.0
plain[1] = x
ruby_time = Benchmark.realtime do
  (2...ruby_length).each do |i|
    w  = x * plain[i-1]
    wy = w - plain[i-2]
    plain[i] = wy + w - wy/i
  end
end

jit_per_element = jit_time / jit_length
ruby_per_element = ruby_time / ruby_length

puts format("compile     %8.1f ms (once)", compile_time * 1e3)
puts format("jit_for    %8.1f ms  n=%-9d %7.2f ns/element",
            jit_time * 1e3, jit_length, jit_per_element * 1e9)
puts format("Ruby loop   %8.1f ms  n=%-9d %7.2f ns/element",
            ruby_time * 1e3, ruby_length, ruby_per_element * 1e9)
puts format("ratio       %8.0fx", ruby_per_element / jit_per_element)
puts
puts format("compilation pays for itself at about %d elements",
            (compile_time / (ruby_per_element - jit_per_element)).ceil)
