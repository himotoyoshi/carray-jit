# CScalar: a value with a home.
#
# A CScalar is the one-cell CArray it subclasses, minus the index.  `s[]` is
# the value and `s[] = ...` puts one back, and that missing index is the whole
# of the difference -- which is why it needed saying to a compiler whose
# kernel language is written in subscripts.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

gain = CScalar.double() { 2.0 }
offset = CScalar.double() { 10.0 }
signal = CArray.double(6).seq!(1.0)
out = CArray.double(6)

# In an expression it is read at every cell, which is what CArray's own
# operators do with it.  Nothing here says it is a scalar; it says so itself.
CArray.jit_each { out = signal * gain + offset }
puts "signal * gain + offset"
puts "  #{out.to_a.inspect}"
puts "  same as CArray's own operators  #{out.to_a == (signal * gain + offset).to_a}"
puts

# And written like any other cell.
CArray.jit_each { gain = gain + 0.5 }
puts "gain after gain[] = gain + 0.5   #{gain[0]}"
puts

# An indexed kernel reaches it too, and there the missing index is the point:
# there is no axis to walk, so there is no index to write.  A bare name says
# the same thing.
indexed = CArray.double(6)
CArray.jit_for(6) { |i| indexed[i] = signal[i] * gain[] }
puts "the same, with the loop written out"
puts "  #{indexed.to_a.inspect}"

bare = CArray.double(6)
CArray.jit_for(6) { |i| bare[i] = signal[i] * gain }
puts "  a bare `gain` agrees  #{bare.to_a == indexed.to_a}"

# It is still the one-cell array it is, so the index spelling keeps working
# and means the same cell.
spelled = CArray.double(6)
CArray.jit_for(6) { |i| spelled[i] = signal[i] * gain[0] }
puts "  and so does gain[0]   #{spelled.to_a == indexed.to_a}"
puts

# Every iteration writes the one cell it has, and what is left is what the
# same Ruby loop leaves -- which makes it an accumulator without asking for
# one.  The inner loop of a reduction rests on exactly this.
total = CScalar.int() { 0 }
counts = CArray.int(4).seq!(1)
CArray.jit_for(4) { |i| total[] = total[] + counts[i] }
puts "total after one pass over #{counts.to_a.inspect}  #{total[0]}"

in_ruby = 0
(0...4).each { |i| in_ruby = in_ruby + counts[i] }
puts "  what the same Ruby loop leaves  #{in_ruby}"
puts

# A contraction takes one as it takes any other operand it does not index.
left = CArray.double(3).seq!(1.0)
right = CArray.double(3).seq!(1.0)
weight = CScalar.double() { 2.0 }
puts "weighted dot product  #{CArray.jit_contract { |k| left[k] * right[k] * weight[] }[0]}"
puts

# What it will not do is take an expression wider than itself, because there
# is one cell and no answer to which of the values lands.  CArray refuses the
# same assignment, in the same terms.
begin
  CArray.jit_each { weight = signal + 1.0 }
rescue CArray::JIT::Unsupported => error
  puts "refused: #{error.message}"
end
begin
  weight[] = signal + 1.0
rescue => error
  puts "CArray:  #{error.message.lines.first.strip[0, 78]}"
end
