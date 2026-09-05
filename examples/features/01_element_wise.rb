# An expression over whole arrays, in one pass.
#
# jit_each is jit_for's sibling, for work that reaches no neighbour: no
# index to name, so no extent to give, and the arrays are written the way
# CArray already spells the whole of one.  What changes is not the expression
# but how it runs -- at the cell, reading the data once, instead of one pass
# per operation with intermediate arrays in between.
#
# Every name in the block is a cell, the loop being this compiler's and not
# written here, so the assignment is Ruby's own: `out = ...` writes the array
# `out` names outside.  jit_map is the same block with its value asked for.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

n = 100_000
a = CArray.double(n).seq!(1.0)
b = CArray.double(n).seq!(0.5, 0.5)
c = CArray.double(n).seq!(2.0, -0.25)
out = CArray.double(n)

CArray.jit_each { out = (a + b) * (c - a) + b * c - a }

# The same expression evaluated by CArray, which allocates an array per
# operation along the way.
expected = (a + b) * (c - a) + b * c - a

puts "element-wise"
puts "  first three cells   #{out[0..2].to_a.inspect}"
puts "  matches CArray      #{out.to_a == expected.to_a}"

# The rank comes from the arrays rather than from the block, so the same
# expression serves whatever shape it is given, and broadcasting costs nothing
# -- a stretched axis arrives as a stride of zero.
matrix = CArray.double(3, 4).seq!(1.0)
row = CArray.double(1, 4).seq!(10.0, 10.0)
scaled = CArray.double(3, 4)

CArray.jit_each { scaled = matrix * row }

puts "  broadcast row       #{scaled.to_a.inspect}"
puts "  matches CArray      #{scaled.to_a == (matrix * row).to_a}"

# jit_map: the same block, with its value asked for.
#
# The last statement is the value every cell of the result gets, and the
# result is allocated here -- typed from that value rather than from the
# arrays -- so there is no output array to name.  The name is what says a
# value comes back; the block is read exactly the same way.

sums = CArray.jit_map { a + b }
puts
puts "asking for the value back"
puts "  first three cells   #{sums[0..2].to_a.inspect}"
puts "  matches CArray      #{sums.to_a == (a + b).to_a}"

# It is the same shape of block CArray.jit_function takes and not the same thing:
# there the loop belongs to whoever calls the function, so the body may close
# over nothing.  Here the loop is ours and the body is inlined into it.
weight = 0.25
blended = CArray.jit_map { a * weight + b * (1.0 - weight) }
puts "  closing over a value #{blended[0..2].to_a.inspect}"

# An assignment is a statement with a value -- Ruby's rule, not a special
# case here -- so a block may write an array of yours and hand the same value
# back.  Which is jit_each's block, asked a different question.
kept = CArray.double(n)
also = CArray.jit_map { kept = a - b }
puts "  written and returned #{kept[0..2].to_a == also[0..2].to_a}"
