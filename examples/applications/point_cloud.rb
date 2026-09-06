# Rotating a point cloud, then projecting it onto a basis
#
# Both are sums over an index that appears twice, which is what
# `CArray.jit_contract` is: the repeated index is summed, so the notation is the
# formula.
#
#   rotated[p,i] = sum_j R[i,j] x[p,j]           rotate every point
#   cov[a,b]     = sum_p c[p,a] c[p,b]           the covariance of the cloud
#   coeff[p,m]   = sum_k x[p,k] basis[m,k]       project onto a basis
#   recon[p,k]   = sum_m coeff[p,m] basis[m,k]   and build the points back
#
# Written as loops these are three lines each and easy to get subtly wrong: an
# index in the wrong place transposes the answer rather than failing.  Here the
# parameter list states the axis order, and an index whose axes disagree is
# refused before anything runs.
#
#   ruby examples/applications/point_cloud.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

count = 200_000
random = Random.new(20260902)

# A flattened, tilted blob: wide in x, narrower in y, nearly flat in z.
points = CArray.double(count, 3) { |p, k| random.rand(-1.0..1.0) }
points[nil, 1] = points[nil, 1] * 0.4
points[nil, 2] = points[nil, 2] * 0.05

angle = Math::PI / 6
rotation = CArray.double(3, 3)
rotation[0, nil] = [Math.cos(angle), -Math.sin(angle), 0.0]
rotation[1, nil] = [Math.sin(angle),  Math.cos(angle), 0.0]
rotation[2, nil] = [0.0, 0.0, 1.0]

# j is summed because it appears twice; p and i are free, and they come out as
# the result's axes in the order the block named them.
rotated = CArray.jit_contract { |p, i, j| points[p, j] * rotation[i, j] }

puts "#{count} points, rotated by #{(angle * 180 / Math::PI).round} degrees"
puts "  spread per axis, before  #{points.stddev(axis: 0).to_a.map { |v| v.round(4) }.inspect}"
puts "  after                    #{rotated.stddev(axis: 0).to_a.map { |v| v.round(4) }.inspect}"

# The covariance: p is the index appearing twice, so p is what is summed --
# the sum over points.  The same axis of the same array is read at two
# independent positions, a and b, which is the whole shape of the thing.
centred = rotated - rotated.mean(axis: 0).reshape(1, 3)
covariance = CArray.jit_contract { |a, b, p| centred[p, a] * centred[p, b] } / count
puts "  covariance"
covariance.to_a.each { |row| puts "    " + row.map { |v| format('%9.5f', v) }.join }

# Its trace does not change under a rotation, which checks both contractions
# at once.
original = points - points.mean(axis: 0).reshape(1, 3)
before = CArray.jit_contract { |a, b, p| original[p, a] * original[p, b] } / count
puts format("  trace %.8f before the rotation, %.8f after",
            CArray.jit_contract { |a| before[a, a] }[0],
            CArray.jit_contract { |a| covariance[a, a] }[0])

# The plane the blob lies in, in the rotated frame: the two rows of the
# rotation are an orthonormal basis for it.
basis = rotation[0..1, nil]

coefficients = CArray.jit_contract { |p, m, k| rotated[p, k] * basis[m, k] }
reconstructed = CArray.jit_contract { |p, k, m| coefficients[p, m] * basis[m, k] }

residual = ((rotated - reconstructed) ** 2).sum / count
puts format("  dropping the third direction costs %.2e per point", residual)
puts format("  which is the variance that was in it: %.2e",
            rotated[nil, 2].stddev ** 2)

# The distance of every point from the origin is *not* a contraction, and this
# is the place the convention bites: in `x[p,k] * x[p,k]` the index p appears
# twice as well, so it would be summed too and the answer would be one number.
# A quantity per point is a per-cell loop, and says so.
squared = CArray.double(count)
CArray.jit_for(count) { |p|
  total = 0.0
  (0...3).each { |k| total = total + rotated[p, k] * rotated[p, k] }
  squared[p] = total
}
puts format("  furthest point %.4f away", Math.sqrt(squared.max))

# The same rotation written as a Ruby loop.
reference = CArray.double(count, 3)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
count.times do |p|
  3.times do |i|
    total = 0.0
    3.times { |j| total += points[p, j] * rotation[i, j] }
    reference[p, i] = total
  end
end
interpreted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
CArray.jit_contract { |p, i, j| points[p, j] * rotation[i, j] }
compiled = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts format("  rotation: %.1f ms compiled, %.0f ms as a Ruby loop (%.0fx)",
            compiled * 1e3, interpreted * 1e3, interpreted / compiled)
puts "  identical: #{rotated.to_a == reference.to_a}"

# An index whose axes disagree is the mistake this notation exists to catch.
begin
  wrong = CArray.double(4, 4).seq!(1.0)
  CArray.jit_contract { |p, i, j| points[p, j] * wrong[i, j] }
rescue CArray::JIT::Unsupported => error
  puts "  refused:  #{error.message.lines.first.strip}"
end
