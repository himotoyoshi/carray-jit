# Steady heat on a plate: Laplace's equation by Jacobi relaxation.
#
# The plate's edges are held at fixed temperatures and the interior settles
# into the average of its neighbours.  One sweep is a five-point stencil, and
# the boundary is the whole difficulty: those cells are data, not something to
# compute, so the sweep has to leave them exactly as it found them.  That is
# `border: :skip`, said at the call -- the loop itself knows nothing about it.
#
# Beside it, the same sweep written over whole arrays, which is what this would
# be without a compiler: four shifted views added, four passes over the plate,
# and a fresh array for each.
#
#   ruby examples/applications/relaxation.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

ROWS, COLUMNS = 120, 160
SWEEPS = 1200

def fresh_plate
  plate = CArray.double(ROWS, COLUMNS)
  plate[nil, 0] = 25.0             # the sides, somewhere in between
  plate[nil, -1] = 25.0
  plate[0, nil] = 100.0            # the top edge is hot, corners included
  plate[-1, nil] = 0.0             # the bottom is held at zero
  plate
end

# One sweep.  `into:` writes the array we already have, and gives it back;
# `border: :skip` leaves the four edges holding the temperatures they were set
# to, so nothing in the kernel has to know that they are the boundary.
def sweep (plate, scratch)
  CArray.jit_stencil(plate, border: :skip, into: scratch) { |a|
    0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
  }
end

plate = fresh_plate
scratch = plate.copy

SWEEPS.times do
  sweep(plate, scratch)
  plate, scratch = scratch, plate
end

puts "the plate after #{SWEEPS} sweeps"
(0...12).map { |t| t * (ROWS - 1) / 11 }.each do |i|
  row = (0...40).map { |t| t * (COLUMNS - 1) / 39 }.map { |j|
    " .:-=+*#%@"[(plate[i, j] / 100.0 * 9).round]
  }.join
  puts "  " + row
end

# The edges are still what they were set to, and the interior is the average
# of its neighbours to within the residual below.
edges_held = plate[0, nil].to_a.all?(100.0) && plate[-1, nil].to_a.all?(0.0)
residual = 0.0
(1...(ROWS-1)).each do |i|
  (1...(COLUMNS-1)).each do |j|
    average = 0.25 * (plate[i-1, j] + plate[i+1, j] + plate[i, j-1] + plate[i, j+1])
    difference = (plate[i, j] - average).abs
    residual = difference if difference > residual
  end
end
puts format("  the edges were left alone   %s", edges_held)
puts format("  largest residual            %.2e", residual)

# The same sweep over whole arrays, for the answer to check against and the
# time to measure against.  The interior is written from four shifted views;
# the boundary is not addressed, which is what :skip does at the call.
def fused_sweep (plate, scratch)
  scratch[1..-2, 1..-2] = 0.25 * (plate[0..-3, 1..-2] + plate[2..-1, 1..-2] +
                                  plate[1..-2, 0..-3] + plate[1..-2, 2..-1])
  scratch
end

fused = fresh_plate
spare = fused.copy
SWEEPS.times do
  fused_sweep(fused, spare)
  fused, spare = spare, fused
end
puts format("  agrees with whole arrays    %s (largest difference %.1e)",
            fused.to_a == plate.to_a, (fused - plate).abs.max)

# What a sweep costs each way.
warm = fresh_plate
warm_scratch = warm.copy
sweep(warm, warm_scratch)

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
100.times { sweep(warm, warm_scratch) }
stencilled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 100

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
100.times { fused_sweep(warm, warm_scratch) }
whole = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 100

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
3.times do
  (1...(ROWS-1)).each do |i|
    (1...(COLUMNS-1)).each do |j|
      warm_scratch[i, j] = 0.25 * (warm[i-1, j] + warm[i+1, j] +
                                   warm[i, j-1] + warm[i, j+1])
    end
  end
end
interpreted = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 3

puts
puts format("a sweep over %d cells", ROWS * COLUMNS)
puts format("  jit_stencil                 %.3f ms", stencilled * 1e3)
puts format("  four shifted views          %.3f ms (%.1fx)", whole * 1e3, whole / stencilled)
puts format("  the same loop in Ruby       %.3f ms (%.0fx)", interpreted * 1e3, interpreted / stencilled)
