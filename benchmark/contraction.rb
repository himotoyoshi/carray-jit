# What naming a contraction's axes costs.
#
# `CArray.jit_contract` sums an index that repeats.  Naming the result's
# axes says which indices are *not* summed, which is the only way to write a
# quantity per point, a diagonal or a batch of products -- there the question
# is not what the naming costs but what the alternative does, since the
# alternative is a loop somewhere else.
#
# Where both spellings exist, they should be the same kernel: the naming is
# read once, when the block is analyzed, and what is cached is the kernel it
# produced.  The first pair below is that check, and the second is the same
# question asked where a call is all there is.
#
# What the numbers after those two say is what a contraction is worth against
# the alternatives: the same work written out with jit_for, the reduction
# CArray already has, and -- where the batch index is named -- a Ruby loop of
# calls, which is the one place the naming itself buys speed.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "carray/jit"

SAMPLES = 5
def median (list) = list.sort[list.size / 2]
def timed (samples) = median(samples.times.map { Benchmark.realtime { yield } })

# A matrix product, which the convention finds on its own, written both ways.
n, k, m = 400, 400, 400
left = CArray.double(n, k).seq!(1)
right = CArray.double(k, m).seq!(1)

CArray.jit_contract { |i, j, t| left[i,t] * right[t,j] }
CArray.jit_contract(:i, :j) { |t| left[i,t] * right[t,j] }

convention = timed(SAMPLES) { CArray.jit_contract { |i, j, t| left[i,t] * right[t,j] } }
named = timed(SAMPLES) { CArray.jit_contract(:i, :j) { |t| left[i,t] * right[t,j] } }

# And the same product as a loop.  Both spellings above are jit_contract and
# this one is not, so it says what the notation costs against writing the
# loop -- which, since a contraction's sum is split into partial ones as this
# loop's is, is nothing.
product = CArray.double(n, m)
CArray.jit_for(n, m) { |i, j|
  accumulator = 0.0
  (0...k).each { |t| accumulator = accumulator + left[i,t] * right[t,j] }
  product[i,j] = accumulator
}
written_out = timed(SAMPLES) {
  CArray.jit_for(n, m) { |i, j|
    accumulator = 0.0
    (0...k).each { |t| accumulator = accumulator + left[i,t] * right[t,j] }
    product[i,j] = accumulator
  }
}

operations = n * m * k
puts "the same matrix product #{n} x #{k} x #{m}, both spellings"
puts format("the convention   %8.1f ms   %5.2f ns per multiply-add",
            convention * 1e3, convention / operations * 1e9)
puts format("the axes named   %8.1f ms   %5.2f ns per multiply-add   %.2fx",
            named * 1e3, named / operations * 1e9, named / convention)
puts format("the same as jit_for %5.1f ms   %5.2f ns per multiply-add   %.2fx",
            written_out * 1e3, written_out / operations * 1e9,
            written_out / convention)

# The per-call cost, where the work is small enough that only the call is
# left: whatever the naming costs, it is paid here or nowhere.
puts
small_left = CArray.double(4, 4).seq!(1)
small_right = CArray.double(4, 4).seq!(1)
rounds = 20_000
CArray.jit_contract { |i, j, t| small_left[i,t] * small_right[t,j] }
CArray.jit_contract(:i, :j) { |t| small_left[i,t] * small_right[t,j] }

small_convention = timed(SAMPLES) {
  rounds.times { CArray.jit_contract { |i, j, t| small_left[i,t] * small_right[t,j] } }
}
small_named = timed(SAMPLES) {
  rounds.times { CArray.jit_contract(:i, :j) { |t| small_left[i,t] * small_right[t,j] } }
}
puts "a 4 x 4 x 4 product, #{rounds} times: the call and nothing else"
puts format("the convention   %8.2f us per call", small_convention / rounds * 1e6)
puts format("the axes named   %8.2f us per call   %.2fx",
            small_named / rounds * 1e6, small_named / small_convention)

# A quantity per point.  The convention cannot write this at all -- p appears
# twice and would be summed -- so what it is measured against is the loop it
# replaces.
puts
count, width = 200_000, 3
points = CArray.double(count, width).seq!(1)
squared = CArray.double(count)

CArray.jit_contract(:p) { |t| points[p,t] * points[p,t] }
contracted = timed(SAMPLES) { CArray.jit_contract(:p) { |t| points[p,t] * points[p,t] } }

CArray.jit_contract(:p) { |t| squared[p] = points[p,t] * points[p,t] }
assigned = timed(SAMPLES) {
  CArray.jit_contract(:p) { |t| squared[p] = points[p,t] * points[p,t] }
}

CArray.jit_for(count) { |p|
  accumulator = 0.0
  (0...width).each { |t| accumulator = accumulator + points[p,t] * points[p,t] }
  squared[p] = accumulator
}
looped = timed(SAMPLES) {
  CArray.jit_for(count) { |p|
    accumulator = 0.0
    (0...width).each { |t| accumulator = accumulator + points[p,t] * points[p,t] }
    squared[p] = accumulator
  }
}

plain = CArray.double(count)
ruby = timed(SAMPLES) {
  (0...count).each do |p|
    accumulator = 0.0
    (0...width).each { |t| accumulator = accumulator + points[p,t] * points[p,t] }
    plain[p] = accumulator
  end
}

native = timed(SAMPLES) { (points ** 2).sum(axis: 1) }

cells = count * width
puts "one number per point, #{count} points of #{width}"
puts format("the axes named   %8.1f ms   %5.2f ns/cell", contracted * 1e3,
            contracted / cells * 1e9)
puts format("  assigned into  %8.1f ms   %5.2f ns/cell   %.2fx",
            assigned * 1e3, assigned / cells * 1e9, assigned / contracted)
puts format("jit_for          %8.1f ms   %5.2f ns/cell   %.2fx",
            looped * 1e3, looped / cells * 1e9, looped / contracted)
puts format("Ruby loop        %8.1f ms   %5.2f ns/cell   %.0fx",
            ruby * 1e3, ruby / cells * 1e9, ruby / contracted)
puts format("(x ** 2).sum(axis: 1) %3.1f ms   %5.2f ns/cell   %.2fx",
            native * 1e3, native / cells * 1e9, native / contracted)

# A sum along an axis, which the naming also allows.  CArray has the
# reduction, and its kernel is written for the shape.
puts
rows, columns = 2_000, 500
source = CArray.double(rows, columns).seq!(1)
CArray.jit_contract(:i) { |t| source[i,t] }
along = timed(SAMPLES) { CArray.jit_contract(:i) { |t| source[i,t] } }
built_in = timed(SAMPLES) { source.sum(axis: 1) }
puts "row sums over #{rows} x #{columns}"
puts format("the axes named   %8.1f ms   %5.2f ns/cell", along * 1e3,
            along / (rows * columns) * 1e9)
puts format("sum(axis: 1)     %8.1f ms   %5.2f ns/cell   %.2fx",
            built_in * 1e3, built_in / (rows * columns) * 1e9, built_in / along)

# A batch of matrix products, where the batch index is named and the loop over
# it is the kernel's rather than Ruby's.
puts
batch, bn, bk, bm = 200, 32, 32, 32
stack = CArray.double(batch, bn, bk).seq!(1)
other = CArray.double(batch, bk, bm).seq!(1)

CArray.jit_contract(:b, :i, :j) { |t| stack[b,i,t] * other[b,t,j] }
batched = timed(SAMPLES) {
  CArray.jit_contract(:b, :i, :j) { |t| stack[b,i,t] * other[b,t,j] }
}

per_matrix = timed(SAMPLES) {
  (0...batch).map { |index|
    one = stack[index, nil, nil]
    two = other[index, nil, nil]
    CArray.jit_contract { |i, j, t| one[i,t] * two[t,j] }
  }
}

batch_operations = batch * bn * bk * bm
puts "#{batch} products of #{bn} x #{bk} x #{bm}"
puts format("the axes named   %8.1f ms   %5.2f ns per multiply-add",
            batched * 1e3, batched / batch_operations * 1e9)
puts format("one call each    %8.1f ms   %5.2f ns per multiply-add   %.2fx",
            per_matrix * 1e3, per_matrix / batch_operations * 1e9,
            per_matrix / batched)
