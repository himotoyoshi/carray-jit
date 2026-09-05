# A recurrence: each cell from the ones before it.
#
# This is the case a vectorised library cannot help with, because cell i is
# not available until cell i-1 has been written.  Reading behind the cell
# being written propagates only upward, and the extent is where that is
# written down -- by the caller, since nothing else can know it was meant.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

# Legendre polynomials at x, by their three-term recurrence.
n = 24
x = 0.5
legendre = CArray.double(n)
legendre[0] = 1.0
legendre[1] = x

CArray.jit_for(2...n) { |i|
  w = x * legendre[i-1]
  wy = w - legendre[i-2]
  legendre[i] = wy + w - wy / i
}

reference = Array.new(n, 0.0)
reference[0] = 1.0
reference[1] = x
(2...n).each do |i|
  w = x * reference[i-1]
  wy = w - reference[i-2]
  reference[i] = wy + w - wy / i
end

puts "Legendre recurrence, x = #{x}"
puts "  P_2 .. P_5            #{legendre[2..5].to_a.inspect}"
puts "  bit-exact vs Ruby     #{legendre.to_a == reference}"

# `wy / i` divides a Float by an Integer, so it is a Float division here as it
# is in Ruby.  Where both sides are integers, the division is floored -- also
# as in Ruby, and not as C would truncate it.
counts = CArray.int32(6)
CArray.jit_for(6) { |i| counts[i] = (i - 4) / 3 }
puts "  floored integer /     #{counts.to_a.inspect} == #{(0...6).map { |i| (i - 4) / 3 }.inspect}"

# A range that would read outside the array is refused before anything runs,
# rather than quietly starting one cell later.
begin
  CArray.jit_for(0...n) { |i| legendre[i] = legendre[i-1] * 2.0 }
rescue CArray::JIT::Unsupported => error
  puts "  refused:              #{error.message.lines.first.strip}"
end
