# Quicksort, written in Ruby and compiled to a C function.
#
# CArray already sorts, and this is not a better sort -- it is the naive
# textbook one, last element as the pivot.  What it shows is that the body of
# a C function can be written here: it takes a pointer and two indices, walks
# the run, swaps through the pointer, and calls itself.  The block stays
# runnable in Ruby, so the same partition can be watched from either side.
#
#   ruby examples/applications/quicksort.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

# The declaration is C's own, and it is what settles everything: `double v[]`
# is a run of numbers the function may write, `int64_t` the indices, and the
# name in the declaration is what puts the function in scope inside its own
# body -- an anonymous `double (*)(...)` has nothing to call itself by.
#
# There is no `void` here because a compiled body has to produce a value, so
# the return is the C convention for "nothing went wrong".
quicksort = CArray.jit_function(
  "int quicksort(double v[], int64_t low, int64_t high)"
) { |v, low, high|
  if low < high
    pivot = v[high]                        # Lomuto's partition, as written
    smaller = low - 1
    scan = low
    while scan < high
      if v[scan] <= pivot
        smaller = smaller + 1
        held = v[smaller]
        v[smaller] = v[scan]
        v[scan] = held
      end
      scan = scan + 1
    end
    held = v[smaller+1]
    v[smaller+1] = v[high]
    v[high] = held
    # Called for what they do to the run; the 0 each answers goes nowhere,
    # which is what a call standing where a statement stands means here and
    # in C.
    quicksort.call(v, low, smaller)
    quicksort.call(v, smaller + 2, high)
  end
  0
}

n = 200_000
random = Random.new(20260905)
values = CArray.double(n) { |i| random.rand }

sorted = values.copy                       # `to_ca` would answer this array
quicksort.call(sorted, 0, n - 1)

puts "quicksort"
puts "  sorted                 #{(0...n-1).all? { |i| sorted[i] <= sorted[i+1] }}"
puts "  same cells as CArray   #{sorted.to_a == values.sort.to_a}"

# The block is still there, and still Ruby.  Run that way the partition is
# interpreted and the two halves go back through the compiled function, which
# is the same body reached by the other road.
in_ruby = values[0...200].copy
quicksort.block.call(in_ruby, 0, 199)
puts "  the block agrees       #{in_ruby.to_a == values[0...200].sort.to_a}"

# ------------------------------------------------------------- what it costs

def timed (repeats)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

scratch = values.copy
compiled = timed(5) { scratch[nil] = values; quicksort.call(scratch, 0, n - 1) }
carray = timed(5) { values.sort }
ruby_array = timed(5) { values.to_a.sort }

def ruby_quicksort (v, low, high)
  return if low >= high
  pivot = v[high]
  smaller = low - 1
  (low...high).each do |scan|
    if v[scan] <= pivot
      smaller += 1
      v[smaller], v[scan] = v[scan], v[smaller]
    end
  end
  v[smaller+1], v[high] = v[high], v[smaller+1]
  ruby_quicksort(v, low, smaller)
  ruby_quicksort(v, smaller + 2, high)
end

interpreted_source = values.to_a
interpreted = timed(1) { ruby_quicksort(interpreted_source.dup, 0, n - 1) }

puts
puts format("%d doubles", n)
puts format("  this quicksort, compiled   %6.1f ms", compiled * 1e3)
puts format("  CArray#sort                %6.1f ms", carray * 1e3)
puts format("  Array#sort                 %6.1f ms", ruby_array * 1e3)
puts format("  the same partition in Ruby %6.1f ms (%.0fx)",
            interpreted * 1e3, interpreted / compiled)

# The textbook partition lands beside CArray#sort, which is the honest
# reading of it: both are C walking the same memory, and this one is measured
# with the copy it needs included.  Beating it was never the point -- CArray
# sorts already.  What the compiled body is worth is the case where no such
# method exists: an order nobody wrote a sort for, a key computed as you go,
# a run inside a structure CArray has no name for.
#
# Two things this naive version keeps that a library sort does not: the pivot
# is the last element, so an already-sorted run partitions n times and the
# recursion is n deep, and a compiled function that recurses too deep is a
# SIGSEGV rather than a SystemStackError.  That is C's bargain, taken here
# along with the pointer.  A median-of-three pivot is three more lines, and
# the reason to write them.
