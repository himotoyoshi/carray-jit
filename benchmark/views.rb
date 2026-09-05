# What each access tier costs, on the same kernel.
#
# The point of folding a view to a stride basis rather than materialising it
# is that a transpose or a column slice is written in place.  This says what
# that is worth, and what the strided loop costs against the contiguous one.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "carray/jit"

LENGTH = 2_000_000
SAMPLES = 5

def run (values)
  CArray.jit_for(1...values.elements) { |i| values[i] = values[i-1] * 0.5 + 1.0 }
end

def timed (array)
  run(array)                                              # warm the cache
  SAMPLES.times.map { Benchmark.realtime { run(array) } }.sort[SAMPLES / 2]
end

def report (label, array)
  tier = CArray::JIT::Access.classify(array)[:tier]
  stride = nil
  CArray::JIT::Access.open([array], [false]) { |b| stride = b.first[:strides].first }
  seconds = timed(array)
  puts format("%-28s tier=%d stride=%-6d %7.1f ms  %6.2f ns/element",
              label, tier, stride, seconds * 1e3, seconds / array.elements * 1e9)
end

entity = CArray.double(LENGTH)
report("entity", entity)

rows = CArray.double(4, LENGTH)
report("contiguous row of a matrix", rows[1, nil])

columns = CArray.double(LENGTH, 2)
report("strided column (pitch 2)", columns[nil, 0])

wide = CArray.double(LENGTH, 8)
report("strided column (pitch 8)", wide[nil, 0])

reversed = CArray.double(LENGTH)
report("reversed (negative stride)", reversed[-1..0])

gathered = CArray.double(LENGTH).seq!
selection = gathered[gathered >= 0.0]
report("gathered (materialised)", selection)

# Is folding a non-contiguous view actually better than copying it out,
# running the contiguous loop, and copying it back?
puts
copy_source = CArray.double(LENGTH, 2)
column = copy_source[nil, 0]
run(column)
folded = SAMPLES.times.map { Benchmark.realtime { run(column) } }.sort[SAMPLES / 2]

copied = SAMPLES.times.map {
  Benchmark.realtime do
    scratch = column.copy
    run(scratch)
    column[] = scratch
  end
}.sort[SAMPLES / 2]

puts format("strided column, folded in place   %7.1f ms", folded * 1e3)
puts format("strided column, copied out and back %5.1f ms", copied * 1e3)
puts format("folding is %.2fx the speed of copying", copied / folded)
