# Views are written in place, without a copy.
#
# A column of a matrix, a transpose, a slice of a slice: these are the things
# views exist for, and a kernel that only accepted a contiguous array would
# make the caller copy them in and out again.  Where a view folds to a stride
# expression -- which a column, a reversal and a transpose all do -- the kernel
# addresses the original memory and the write lands in the parent.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

# A column: its stride is the row pitch, not the element size.
matrix = CArray.double(8, 3)
column = matrix[nil, 1]
column[0] = 1.0

CArray.jit_for(1...8) { |i| column[i] = column[i-1] * 2.0 + 1.0 }

puts "views"
puts "  column written    #{matrix[nil, 1].to_a.inspect}"
puts "  others untouched  #{matrix[nil, 0].to_a.all?(0.0) && matrix[nil, 2].to_a.all?(0.0)}"

# A reversed view has a negative stride, and a slice of a slice folds to one
# offset and one stride however many times it was sliced.
array = CArray.double(20).seq!
inner = array[4..15][2..9]
CArray.jit_for(8) { |i| inner[i] = -inner[i] }
puts "  slice of a slice  #{array[5..14].to_a.inspect}"

# A transpose is read at its own indices; nothing is materialised.
source = CArray.double(4, 3).seq!(1.0)
transposed = source.transpose
result = CArray.double(3, 4)
CArray.jit_for(*transposed.dim) { |i, j| result[i, j] = transposed[i, j] * 2.0 }
puts "  transposed read   #{result.to_a == (source.transpose * 2.0).to_a}"

# A view with no stride expression -- a gather, say -- cannot be addressed
# arithmetically, so the cells the kernel asked for are transferred and written
# back.  The cost is proportional to the region, not to the view: the kernel
# knows its extents and its offsets before it runs, so it asks for the box it
# will touch and no more.
whole = CArray.double(64).seq!
gathered = whole[whole >= 0.0]
gathered[10] = 1.0
CArray.jit_for(11...14) { |i| gathered[i] = gathered[i-1] * 2.0 }
puts "  gather region     #{whole[9..14].to_a.inspect} (9 and 14 outside the box)"
