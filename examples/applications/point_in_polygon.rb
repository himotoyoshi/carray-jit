# Which of a million points are inside a polygon.
#
# The test is the old one: send a ray out from the point and count the edges
# it crosses; an odd count means inside.  Counting is a loop over the edges,
# and the count is one integer that belongs to the point.
#
# An array expression cannot keep that integer.  It can compare a point
# against an edge -- but the comparison has to be made for every point and
# every edge, and holding those answers is an array of points by edges.  With
# a million points and two hundred edges that is a temporary of 1.5 GB, built
# so that it can immediately be summed away.  The kernel keeps the count in a
# register and the polygon is read where it lies.
#
#   ruby examples/applications/point_in_polygon.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

EDGES = 200
POINTS = 1_000_000

# A lobed blob, closed, going round once.
corner_x = CArray.double(EDGES)
corner_y = CArray.double(EDGES)
CArray.jit_for(EDGES) { |k|
  angle = 2.0 * Math::PI * k / EDGES
  radius = 1.0 + 0.35 * Math.sin(7.0 * angle) + 0.15 * Math.cos(3.0 * angle)
  corner_x[k] = radius * Math.cos(angle)
  corner_y[k] = radius * Math.sin(angle)
}

random = CArray::Rng.new(seed: 20260913)
point_x = CArray.double(POINTS)
point_x.random!(rng: random)
point_x = point_x * 3.2 - 1.6
point_y = CArray.double(POINTS)
point_y.random!(rng: random)
point_y = point_y * 3.2 - 1.6

inside = CArray.int8(POINTS)

def classify (point_x, point_y, corner_x, corner_y, inside)
  edges = corner_x.elements
  CArray.jit_for(point_x.elements) { |i|
    x = point_x[i]
    y = point_y[i]
    crossings = 0
    k = 0
    while k < edges
      j = k == 0 ? edges - 1 : k - 1
      this_y = corner_y[k]
      last_y = corner_y[j]
      # The edge has to straddle the ray for the crossing to count, and the
      # test is written so that a vertex exactly on the ray counts once.
      if (this_y > y) != (last_y > y)
        cut = corner_x[j] + (y - last_y) * (corner_x[k] - corner_x[j]) / (this_y - last_y)
        crossings = crossings + 1 if x < cut
      end
      k = k + 1
    end
    inside[i] = crossings % 2
  }
end

classify(point_x, point_y, corner_x, corner_y, inside)

puts format("%d points against a polygon of %d edges", POINTS, EDGES)
puts format("  inside  %d  (%.1f%% of the square they were drawn in)",
            inside.sum, 100.0 * inside.sum / POINTS)

# The same test in Ruby, over as many points as is polite to wait for.
SAMPLE = 20_000

def classify_in_ruby (x, y, corner_x, corner_y)
  edges = corner_x.elements
  odd = false
  j = edges - 1
  (0...edges).each do |k|
    if (corner_y[k] > y) != (corner_y[j] > y)
      cut = corner_x[j] + (y - corner_y[j]) *
            (corner_x[k] - corner_x[j]) / (corner_y[k] - corner_y[j])
      odd = !odd if x < cut
    end
    j = k
  end
  odd ? 1 : 0
end

def timed (repeats = 3)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

agree = (0...SAMPLE).all? { |i|
  inside[i] == classify_in_ruby(point_x[i], point_y[i], corner_x, corner_y)
}
puts format("  agrees with Ruby over the first %d  %s", SAMPLE, agree)

compiled = timed { classify(point_x, point_y, corner_x, corner_y, inside) }
interpreted = timed(1) {
  SAMPLE.times { |i| classify_in_ruby(point_x[i], point_y[i], corner_x, corner_y) }
}

puts
puts format("  %6.0f ms here for %d points", compiled * 1e3, POINTS)
puts format("  %6.0f ms in Ruby for %d, so about %.0f s for the million",
            interpreted * 1e3, SAMPLE, interpreted * POINTS / SAMPLE)
puts format("  the array route would hold %d x %d doubles on the way -- %.1f GB,",
            POINTS, EDGES, POINTS.to_f * EDGES * 8 / (1 << 30))
puts        "  built only to be summed away; this one holds one integer, in a register"
