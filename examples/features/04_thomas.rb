# The Thomas algorithm: two sweeps in opposite directions.
#
# The back substitution reads x[i+1] -- ahead of the cell it writes -- so it
# has to run downward to propagate.  `(n-2).step(0, -1)` is that, and is the
# spelling Ruby itself iterates backwards with; `(n-2)..0` is refused, because
# Ruby gives that Range no elements and the same loop written by hand would do
# nothing.
#
# The forward sweep also shows why a kernel writes as many arrays as it likes:
# cc and dd share a denominator, and splitting them in two would compute it
# twice.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

n = 2_000
random = Random.new(20260902)

# A diagonally dominant tridiagonal system: a is the subdiagonal, b the
# diagonal, c the superdiagonal, d the right-hand side.
a = CArray.double(n) { random.rand(-1.0..1.0) }
c = CArray.double(n) { random.rand(-1.0..1.0) }
b = CArray.double(n) { |i| 4.0 + random.rand }
d = CArray.double(n) { random.rand(-1.0..1.0) }
a[0] = 0.0
c[n-1] = 0.0

cc = CArray.double(n)
dd = CArray.double(n)
x  = CArray.double(n)

cc[0] = c[0] / b[0]
dd[0] = d[0] / b[0]

CArray.jit_for(1...n) { |i|                        # upward: reads cc[i-1]
  denominator = b[i] - a[i] * cc[i-1]
  cc[i] = c[i] / denominator
  dd[i] = (d[i] - a[i] * dd[i-1]) / denominator
}

x[n-1] = dd[n-1]
CArray.jit_for((n-2).step(0, -1)) { |i|            # downward: reads x[i+1]
  x[i] = dd[i] - cc[i] * x[i+1]
}

# Multiply the solution back through the original system and look at what is
# left over.
residual = 0.0
n.times do |i|
  row = b[i] * x[i]
  row += a[i] * x[i-1] if i > 0
  row += c[i] * x[i+1] if i < n - 1
  residual = [residual, (row - d[i]).abs].max
end

puts "Thomas algorithm, n = #{n}"
puts "  x[0..2]                #{x[0..2].to_a.inspect}"
puts "  max |A x - d|          #{format('%.3e', residual)}"

# The extent is where the algorithm is stated, and nothing second-guesses it.
# Run the same body upward and it computes something else -- not an error, but
# not back substitution either: each cell reads an x[i+1] the sweep has not
# reached yet.  It is the answer the same Ruby loop gives, which is the only
# thing this promises.
wrong_way = CArray.double(n)
wrong_way[n-1] = dd[n-1]
CArray.jit_for(0...(n-1)) { |i| wrong_way[i] = dd[i] - cc[i] * wrong_way[i+1] }

in_ruby = Array.new(n) { |i| i == n-1 ? dd[n-1] : 0.0 }
(0...(n-1)).each { |i| in_ruby[i] = dd[i] - cc[i] * in_ruby[i+1] }

wrong_residual = 0.0
n.times do |i|
  row = b[i] * wrong_way[i]
  row += a[i] * wrong_way[i-1] if i > 0
  row += c[i] * wrong_way[i+1] if i < n - 1
  wrong_residual = [wrong_residual, (row - d[i]).abs].max
end

puts "  same body, upward      max |A x - d| = #{format('%.3e', wrong_residual)}"
puts "  ...which is what Ruby's own loop gives: #{wrong_way.to_a == in_ruby}"
