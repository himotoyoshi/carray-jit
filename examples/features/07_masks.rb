# Masks: cells that hold no value.
#
# `a[i] == UNDEF` is how Ruby already asks whether a cell is missing, and it
# means the same here -- it reads the mask byte, never the value.  Asking about
# the mask is not reading the value, so what the branch writes carries no mask,
# which is what makes filling a hole possible.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

n = 7
source = CArray.double(n).seq!(1.0)
source[2] = UNDEF

# Filling the holes.  This is an ordinary Ruby loop as well, so it can be
# checked against one.
filled = CArray.double(n)
CArray.jit_for(n) { |i|
  if source[i] == UNDEF
    filled[i] = 0.0
  else
    filled[i] = Math.sqrt(source[i])
  end
}

reference = (0...n).map { |i| source[i] == UNDEF ? 0.0 : Math.sqrt(source[i]) }

puts "masks"
puts "  filled            #{filled.to_a.map { |e| e.round(4) }.inspect}"
puts "  matches Ruby      #{filled.to_a == reference}"
# The array that was written gets a mask because the kernel is a masked one;
# what matters is that no cell in it is missing.
puts "  cells missing     #{filled.count_masked} (a mask exists, but it is empty)"

# Left implicit, the mask propagates as CArray's own operators propagate it:
# any cell that fed a result masks that result, following the offsets, so each
# output takes its mask from its own inputs rather than from everything the
# body read.
neighbours = CArray.double(n)
CArray.jit_for(1...(n-1)) { |i| neighbours[i] = source[i-1] + source[i+1] }
puts "  propagated        #{neighbours.to_a.inspect}"
puts "  masked where      #{(0...n).select { |i| neighbours[i] == UNDEF }.inspect} (the cells reading source[2])"

# Writing UNDEF marks a cell missing.  Mentioning UNDEF at all makes the kernel
# a masked one, whatever its arrays happen to carry.
clipped = CArray.double(n).seq!(1.0)
CArray.jit_for(n) { |i|
  if clipped[i] > 4.0
    clipped[i] = UNDEF
  end
}
puts "  marked missing    #{clipped.to_a.inspect}"

# A branch with no else writes nothing on the path not taken, so those cells
# keep both their value and their mask -- as the same `if` would in Ruby.
