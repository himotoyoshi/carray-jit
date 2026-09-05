# Heat diffusion in a rod, solved implicitly
#
# The explicit scheme is a stencil and is easy; it is also unstable unless the
# time step is tiny.  The implicit one is stable at any step, at the price of
# solving a tridiagonal system every step -- and that solver is two sequential
# sweeps, which is exactly what an array library cannot vectorise for you.
#
# So this is the shape a lot of numerical code has: an outer loop in Ruby, and
# per step a couple of kernels that do the work.
#
#   ruby examples/applications/heat_equation.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

n = 400            # points along the rod
steps = 2_000
dx = 1.0 / (n - 1)
dt = 2.5e-5        # eight times the step an explicit scheme would survive
r = dt / (dx * dx)

temperature = CArray.double(n)
# A hot band in the middle of a cold rod, ends held at zero.
CArray.jit_for(n) { |i| temperature[i] = 0.0 }
(n * 4 / 10...(n * 6 / 10)).each { |i| temperature[i] = 1.0 }

initial_heat = temperature.sum * dx

# Backward Euler: (1 + 2r) T[i] - r T[i-1] - r T[i+1] = T_old[i], which is
# tridiagonal with constant coefficients.
lower = -r
diagonal = 1.0 + 2.0 * r
upper = -r

cc = CArray.double(n)
dd = CArray.double(n)

def solve (temperature, cc, dd, lower, diagonal, upper, n)
  cc[0] = 0.0                      # boundary: T[0] fixed
  dd[0] = temperature[0]

  CArray.jit_for(1...n) { |i|     # forward sweep
    denominator = diagonal - lower * cc[i-1]
    cc[i] = upper / denominator
    dd[i] = (temperature[i] - lower * dd[i-1]) / denominator
  }

  # boundary: T[n-1] fixed
  dd[n-1] = temperature[n-1]
  temperature[n-1] = dd[n-1]

  CArray.jit_for((n-2).step(0, -1)) { |i|   # back substitution
    temperature[i] = dd[i] - cc[i] * temperature[i+1]
  }
end

def draw (temperature, label)
  n = temperature.dim[0]
  row = (0...72).map { |k|
    value = temperature[k * (n - 1) / 71]
    " .:-=+*#@"[[(value * 8).round, 8].min] || " "
  }
  puts "  #{label.rjust(6)} |#{row.join}|"
end

puts "rod of #{n} points, #{steps} implicit steps of dt = #{format('%.1e', dt)}"
puts format("  an explicit scheme would need dt < %.1e here", dx * dx / 2)
draw(temperature, "0")

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
steps.times do |step|
  solve(temperature, cc, dd, lower, diagonal, upper, n)
  draw(temperature, (step + 1).to_s) if [50, 200, 800, 2000].include?(step + 1)
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts format("  %.0f ms for %d steps -- %.1f us per solve of %d unknowns",
            elapsed * 1e3, steps, elapsed / steps * 1e6, n)

# The same solve written as Ruby loops, for comparison.  At n = 400 a fair
# part of the compiled time is the two kernel calls rather than the arithmetic
# in them, so this is the regime where the gap is smallest -- and it is still
# worth having.
def ruby_solve (temperature, cc, dd, lower, diagonal, upper, n)
  cc[0] = 0.0
  dd[0] = temperature[0]
  (1...n).each do |i|
    denominator = diagonal - lower * cc[i-1]
    cc[i] = upper / denominator
    dd[i] = (temperature[i] - lower * dd[i-1]) / denominator
  end
  dd[n-1] = temperature[n-1]
  temperature[n-1] = dd[n-1]
  (n-2).step(0, -1) do |i|
    temperature[i] = dd[i] - cc[i] * temperature[i+1]
  end
end

def time (repeats)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

[400, 4_000, 40_000].each do |size|
  field = CArray.double(size).seq! { |i| i.to_f / size }
  work = [CArray.double(size), CArray.double(size)]
  compiled = time(20) { solve(field, *work, lower, diagonal, upper, size) }
  interpreted = time(3) { ruby_solve(field, *work, lower, diagonal, upper, size) }
  puts format("  n = %6d   %7.1f us compiled   %8.1f us Ruby   %3.0fx",
              size, compiled * 1e6, interpreted * 1e6, interpreted / compiled)
end

# Heat leaves through the ends, so the total falls; what it must not do is
# oscillate or blow up, which is the whole reason for solving implicitly.
puts format("  heat: %.4f initially, %.4f now, peak temperature %.4f",
            initial_heat, temperature.sum * dx, temperature.max)
