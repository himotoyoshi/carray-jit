# Reductions: an inner loop per output cell.
#
# The caller says where the answer goes and the kernel fills that cell.  What
# makes it expressible is `(from...to).each { |j| ... }` -- an inner loop whose
# index addresses arrays but writes nothing -- so sum, maximum, product, count
# and a dot product all fall out of ordinary block-locals, with no primitive
# for any of them.  `n.times { |j| ... }` is the same loop from zero.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

rows, columns = 5, 7
source = CArray.double(rows, columns).seq!(1.0)
total = CArray.double(rows)
largest = CArray.double(rows)
positives = CArray.int32(rows)

CArray.jit_for(rows) { |i|
  accumulator = 0.0
  (0...columns).each { |j| accumulator = accumulator + source[i, j] }
  total[i] = accumulator
}

CArray.jit_for(rows) { |i|
  best = source[i, 0]
  (1...columns).each { |j|
    if source[i, j] > best
      best = source[i, j]
    end
  }
  largest[i] = best
}

CArray.jit_for(rows) { |i|
  count = 0
  (0...columns).each { |j|
    if source[i, j] > 20.0
      count = count + 1
    end
  }
  positives[i] = count
}

puts "row reductions"
puts "  sum      #{total.to_a.inspect}"
puts "  matches  #{total.to_a == source.to_a.map { |row| row.sum }}"
puts "  max      #{largest.to_a.inspect}"
puts "  count    #{positives.to_a.inspect}"

# A matrix multiply is the same shape of thing: two output indices and one
# inner loop.
left = CArray.double(3, 4).seq!(1.0)
right = CArray.double(4, 2).seq!(0.5, 0.5)
product = CArray.double(3, 2)

CArray.jit_for(3, 2) { |i, j|
  accumulator = 0.0
  (0...4).each { |t| accumulator = accumulator + left[i, t] * right[t, j] }
  product[i, j] = accumulator
}

reference = Array.new(3) { |i| Array.new(2) { |j|
  (0...4).sum { |t| left[i, t] * right[t, j] } } }

puts "  matmul   #{product.to_a.inspect}"
puts "  matches  #{product.to_a == reference}"

# The accumulator is split into partial sums, as sum(axis:) splits its own:
# a serial chain waits out the latency of each addition, and the split answer
# is usually the more accurate one as well as the faster.  It is not the order
# the same loop takes in Ruby, and `reassociate: false` is what asks for that.
#
# CArray's own reductions are faster than this still, their kernels being
# written for the shape.  What this is for is the reductions that have no such
# method -- the ones where the body is an algorithm rather than an operator.
puts "  note     CArray#sum(axis: 1) is the faster way to write the first one"
puts

# Counting from zero is what an inner loop mostly does, and `n.times` says it
# without naming an end.  It compiles to the loop the range spells out --
# `(0...n).each` -- so the choice is the reader's, not the compiler's.
counted = CArray.double(rows)
CArray.jit_for(rows) { |i|
  accumulator = 0.0
  columns.times { |j| accumulator = accumulator + source[i, j] }
  counted[i] = accumulator
}
puts "the same sums, written with times"
puts "  #{counted.to_a.inspect}"
puts "  matches the range spelling  #{counted.to_a == total.to_a}"
