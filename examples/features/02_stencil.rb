# A stencil: each cell from its neighbours.
#
# Naming the indices is what lets a kernel reach a neighbouring cell, and the
# extents say which cells are written -- here the interior, leaving the border
# alone.  The offsets mean what they mean in Ruby: src[i-1, j] is the cell at
# index i-1.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

rows, columns = 6, 8
src = CArray.double(rows, columns).seq!(1.0)
out = CArray.double(rows, columns)

CArray.jit_for(1...(rows-1), 1...(columns-1)) { |i, j|
  out[i, j] = 0.25 * (src[i-1, j] + src[i+1, j] + src[i, j-1] + src[i, j+1])
}

reference = CArray.double(rows, columns)
(1...(rows-1)).each do |i|
  (1...(columns-1)).each do |j|
    reference[i, j] = 0.25 * (src[i-1, j] + src[i+1, j] + src[i, j-1] + src[i, j+1])
  end
end

puts "five-point stencil"
puts "  interior matches the Ruby loop   #{out.to_a == reference.to_a}"
puts "  border untouched                 #{out[0, nil].to_a.all?(0.0)}"

# An extent may step by more than one, which changes which cells are written
# and therefore which offsets are dependencies: with a step of two, a[i-1] is
# a cell this loop never writes.
values = CArray.double(10).seq!(1.0)
CArray.jit_for((2...10).step(2)) { |i| values[i] = values[i-1] * 100.0 }
puts "  every other cell                 #{values.to_a.inspect}"

# Written this way the border is what the extents avoid, and the cells there
# keep whatever the output array held -- zeros, which cannot be told from
# zeros that were computed.  The same stencil with the loop implied and the
# edge said at the call is jit_stencil's; see 14_stencil_window.rb.
