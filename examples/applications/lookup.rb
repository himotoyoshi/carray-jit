# Half a million queries against an uneven grid.
#
# Tabulated data rarely comes on a regular grid -- a sounding is dense near
# the ground, a spectrum near a line -- so reading a value off it means
# finding which two samples a query falls between, and that is a search per
# query.  The loop is short, about `log n` steps, but where it looks is
# different for every cell, which is the part an expression over whole arrays
# cannot express: it has no way to say "this cell reads knots[lo] where lo is
# what this cell just worked out".
#
# CArray can still do it, by materialising the answer to the search as an
# index array and gathering through it, and that is measured here beside the
# kernel.  The two agree to the bit; what differs is how many passes and how
# much scratch it took -- and, in the search itself, what may be assumed
# about the grid.
#
#   ruby examples/applications/lookup.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

N = 2_000                               # samples in the table
Q = 500_000                             # queries against it

# A grid that crowds towards zero, and a function sampled on it.
knots = (CArray.double(N).seq!(0, 1.0 / (N - 1)) ** 2) * 100
table = knots.sin
query = CArray.double(Q).seq!(0, 99.9 / Q)

# The search and the interpolation in one pass.  `lo` and `hi` are the cell's
# own, so the kernel reads `knots[lo]` at an address no other cell shares --
# a gather, written as the subscript it is.
def interpolate (knots, table, query)
  n = knots.elements
  out = CArray.double(query.elements)
  CArray.jit_for(query.elements) { |i|
    t = query[i]
    lo = 0
    hi = n - 1
    while hi - lo > 1
      mid = (lo + hi) / 2
      if knots[mid] > t
        hi = mid
      else
        lo = mid
      end
    end
    weight = (t - knots[lo]) / (knots[lo + 1] - knots[lo])
    out[i] = table[lo] * (1.0 - weight) + table[lo + 1] * weight
  }
  out
end

# The same answer over whole arrays.  `search_nearest` is CArray's own and is
# not a loop in Ruby -- but it answers with the nearest sample rather than the
# one below, so the bracket has to be fixed up, and every step from here on is
# another pass and another array the size of the queries.
#
# It is also the slowest line here, and that is a contract rather than a
# fault: nothing says a CArray is sorted, so `search_nearest` looks at every
# sample for every query.  A kernel is where the grid being monotonic can be
# used, because the search is written rather than called.
def interpolate_over_arrays (knots, table, query)
  near = knots.search_nearest(query)
  lo = near.to_ca
  lo[knots[near].gt(query)] -= 1
  lo = lo.clip(0, knots.elements - 2)
  hi = lo + 1
  weight = (query - knots[lo]) / (knots[hi] - knots[lo])
  table[lo] * (1.0 - weight) + table[hi] * weight
end

# And in Ruby, which is where this calculation usually lives.
def interpolate_in_ruby (knots, table, query)
  ks = knots.to_a
  ts = table.to_a
  query.to_a.map { |t|
    lo = 0
    hi = ks.size - 1
    while hi - lo > 1
      mid = (lo + hi) / 2
      if ks[mid] > t then hi = mid else lo = mid end
    end
    weight = (t - ks[lo]) / (ks[lo + 1] - ks[lo])
    ts[lo] * (1.0 - weight) + ts[lo + 1] * weight
  }
end

here = interpolate(knots, table, query)
there = interpolate_over_arrays(knots, table, query)

puts format("%d queries against %d uneven samples", Q, N)
puts format("  agrees with the whole-array route  %s", (here - there).abs.max == 0.0)
puts format("  agrees with Ruby                   %s", here.to_a == interpolate_in_ruby(knots, table, query))
puts format("  worst interpolation error          %.2e", (here - query.sin).abs.max)
puts format("  and where the grid is coarsest     x = %.1f",
            query[(here - query.sin).abs.max_addr])

def timed (repeats = 5)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

compiled = timed { interpolate(knots, table, query) }
searched = timed { knots.search_nearest(query) }
whole = timed { interpolate_over_arrays(knots, table, query) }
interpreted = timed(1) { interpolate_in_ruby(knots, table, query) }

puts
puts format("  one kernel, search and all      %7.1f ms", compiled * 1e3)
puts format("  whole arrays, after the search  %7.1f ms   %.1fx",
            (whole - searched) * 1e3, (whole - searched) / compiled)
puts format("  whole arrays, with it           %7.1f ms   %.0fx",
            whole * 1e3, whole / compiled)
puts format("  Ruby, bisecting per query       %7.1f ms   %.0fx",
            interpreted * 1e3, interpreted / compiled)

# The middle line is the one about style: six passes over half a million
# elements, and the arrays to hold them, against one pass that keeps `lo` in a
# register.  The line below it is about the search, and belongs to
# `search_nearest`'s contract rather than to arrays.
puts
puts format("  arrays of %d elements the whole-array route holds: 7", Q)
puts format("  the kernel holds none, and bisects in %d comparisons",
            Math.log2(N).ceil)
