# Reductions and a matrix multiply, against the same loops written in Ruby.
#
# A reduction is a per-cell computation like any other -- the caller says
# where the answer goes -- so what makes it expressible is an inner loop whose
# index reads but never writes.  The accumulator is then an ordinary local.
#
# Floating-point addition is not associative, so a serial accumulator is one
# dependent chain and cannot be split.  A kernel splits it anyway by default,
# into partial sums, as CArray's own reduce kernels do -- `reassociate: false`
# is what asks for the serial order, and both are measured here.  The two
# compute different numbers, and the partial sums are usually the more
# accurate ones.
#
# Where CArray already has the reduction it is faster still, its kernels being
# written for the shape.  The point of writing one by hand is the reductions
# CArray does not have.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "carray/jit"

SAMPLES = 5
def median (list) = list.sort[list.size / 2]
def timed (samples) = median(samples.times.map { Benchmark.realtime { yield } })

rows, columns = 2_000, 500
source = CArray.double(rows, columns).seq!(1)
total = CArray.double(rows)

CArray.jit_for(rows) { |i|
  accumulator = 0.0
  (0...columns).each { |j| accumulator = accumulator + source[i, j] }
  total[i] = accumulator
}

jit = timed(SAMPLES) {
  CArray.jit_for(rows) { |i|
    accumulator = 0.0
    (0...columns).each { |j| accumulator = accumulator + source[i, j] }
    total[i] = accumulator
  }
}

serial = timed(SAMPLES) {
  CArray.jit_for(rows, reassociate: false) { |i|
    accumulator = 0.0
    (0...columns).each { |j| accumulator = accumulator + source[i, j] }
    total[i] = accumulator
  }
}

plain = CArray.double(rows)
ruby = timed(SAMPLES) {
  (0...rows).each do |i|
    accumulator = 0.0
    (0...columns).each { |j| accumulator = accumulator + source[i, j] }
    plain[i] = accumulator
  end
}

native = timed(SAMPLES) { source.sum(axis: 1) }

cells = rows * columns
puts "row sums over #{rows} x #{columns}"
puts format("jit_for         %8.1f ms   %5.2f ns/cell", jit * 1e3, jit / cells * 1e9)
puts format("  reassociate: false %6.1f ms   %5.2f ns/cell   %.2fx",
            serial * 1e3, serial / cells * 1e9, serial / jit)
puts format("Ruby loop        %8.1f ms   %5.2f ns/cell   %.0fx",
            ruby * 1e3, ruby / cells * 1e9, ruby / jit)
puts format("sum(axis: 1)     %8.1f ms   %5.2f ns/cell   %.2fx",
            native * 1e3, native / cells * 1e9, native / jit)

puts
n, k, m = 300, 300, 300
left = CArray.double(n, k).seq!(1)
right = CArray.double(k, m).seq!(1)
result = CArray.double(n, m)

CArray.jit_for(n, m) { |i, j|
  accumulator = 0.0
  (0...k).each { |t| accumulator = accumulator + left[i, t] * right[t, j] }
  result[i, j] = accumulator
}
multiply = timed(SAMPLES) {
  CArray.jit_for(n, m) { |i, j|
    accumulator = 0.0
    (0...k).each { |t| accumulator = accumulator + left[i, t] * right[t, j] }
    result[i, j] = accumulator
  }
}
multiply_serial = timed(SAMPLES) {
  CArray.jit_for(n, m, reassociate: false) { |i, j|
    accumulator = 0.0
    (0...k).each { |t| accumulator = accumulator + left[i, t] * right[t, j] }
    result[i, j] = accumulator
  }
}
operations = n * m * k
puts "matrix multiply #{n} x #{k} x #{m}"
puts format("jit_for         %8.1f ms   %5.2f ns per multiply-add   %.2f GFLOP/s",
            multiply * 1e3, multiply / operations * 1e9,
            2.0 * operations / multiply / 1e9)
puts format("  reassociate: false %6.1f ms   %5.2f ns per multiply-add   %.2f GFLOP/s",
            multiply_serial * 1e3, multiply_serial / operations * 1e9,
            2.0 * operations / multiply_serial / 1e9)
puts "(a plain triple loop, not a blocked GEMM: the point is that it can be"
puts " written at all, not that it competes with BLAS)"
