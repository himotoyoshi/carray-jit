# Kepler's equation, by Newton's method.
#
#   M = E - e sin E
#
# Given the mean anomaly M of a body on an ellipse, the eccentric anomaly E is
# what the equation has to be solved for, and there is no closed form.  Newton
# converges in a handful of passes -- but not the same handful for every cell:
# near e = 1 and M = 0 the correction is small and the iteration crawls, while
# a nearly circular orbit is done in two.
#
# So the number of passes is a property of the cell, not of the program, and
# that is what `while` is for.  A cap in an extent would be the wrong shape
# here: it would have to be the worst cell's count, and every other cell would
# be written to iterate as long as the worst one.
#
#   ruby examples/applications/kepler.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

n = 200_000
tolerance = 1e-13

mean_anomaly = CArray.double(n) { |i| 2.0 * Math::PI * i / n - Math::PI }

def solve (mean_anomaly, eccentricity, tolerance)
  eccentric = CArray.double(mean_anomaly.elements)
  CArray.jit_for(mean_anomaly.elements) { |i|
    guess = mean_anomaly[i]                     # good enough for any e < 1
    step = 1.0
    # The condition is read at the top of every pass, as Ruby's is, so `step`
    # has to be a local before the loop -- a name the body alone assigned
    # would not be in scope where the condition wants it.
    while step.abs > tolerance
      step = (guess - eccentricity * Math.sin(guess) - mean_anomaly[i]) /
             (1.0 - eccentricity * Math.cos(guess))
      guess = guess - step
    end
    eccentric[i] = guess
  }
  eccentric
end

puts "Kepler's equation over #{n} anomalies"
[0.0167, 0.2056, 0.6, 0.9].each do |eccentricity|
  eccentric = solve(mean_anomaly, eccentricity, tolerance)
  # The check is the equation itself: put E back and see whether M comes out.
  residual = (eccentric - eccentricity * eccentric.sin - mean_anomaly).abs.max
  puts format("  e = %.4f   largest residual %.2e", eccentricity, residual)
end

# How many passes each cell took, which is the thing the extent could not have
# known.  Counting is a second local; the loop is otherwise the same.
eccentricity = 0.9
passes = CArray.int32(n)
roots = CArray.double(n)
CArray.jit_for(n) { |i|
  guess = mean_anomaly[i]
  step = 1.0
  taken = 0
  while step.abs > tolerance
    step = (guess - eccentricity * Math.sin(guess) - mean_anomaly[i]) /
           (1.0 - eccentricity * Math.cos(guess))
    guess = guess - step
    taken = taken + 1
  end
  roots[i] = guess
  passes[i] = taken
}

puts
puts "at e = 0.9"
puts "  passes                 #{passes.min}..#{passes.max}, #{format('%.2f', passes.sum.to_f / n)} on average"
puts "  the slowest cell is    M = #{format('%.4f', mean_anomaly[passes.max_addr])}"
puts "  a cap in an extent     would have been #{passes.max} for every cell"

# The same loop written in Ruby.  A `while` in the kernel is Ruby's `while`:
# the condition is read at the top of every pass, `step` is a local before the
# loop, and no accumulation is reassociated -- so the two take the same passes
# over the same arithmetic.
in_ruby = CArray.double(n)
(0...n).each do |i|
  guess = mean_anomaly[i]
  step = 1.0
  while step.abs > tolerance
    step = (guess - eccentricity * Math.sin(guess) - mean_anomaly[i]) /
           (1.0 - eccentricity * Math.cos(guess))
    guess = guess - step
  end
  in_ruby[i] = guess
end

# What they do not share is the sine.  A few hundred cells come out a bit
# apart, and it is worth finding where that comes from before blaming the
# loop, because it is not the loop: the kernel asks for the sine and the
# cosine of the same argument in the same pass, and the C compiler answers
# both with one call to the library's `sincos`, which rounds a few arguments
# differently from `sin` on its own.  Ruby calls `sin`.
differing = (0...n).count { |i| roots[i] != in_ruby[i] }

iterate = CArray.double(n)                    # one Newton step, in Ruby
(0...n).each do |i|
  guess = mean_anomaly[i]
  iterate[i] = guess - (guess - eccentricity * Math.sin(guess) - mean_anomaly[i]) /
                       (1.0 - eccentricity * Math.cos(guess))
end

alone = CArray.double(n)
CArray.jit_for(n) { |i| alone[i] = Math.sin(iterate[i]) }
together = CArray.double(n)
unused = CArray.double(n)
CArray.jit_for(n) { |i|
  together[i] = Math.sin(iterate[i])
  unused[i] = Math.cos(iterate[i])
}

puts format("  differs from Ruby      %d of %d cells, largest %.1e",
            differing, n, (roots - in_ruby).abs.max)
puts format("  a sine on its own      differs from Ruby's for %d arguments",
            (0...n).count { |i| alone[i] != Math.sin(iterate[i]) })
puts format("  a sine beside a cosine differs for %d of the same arguments",
            (0...n).count { |i| together[i] != Math.sin(iterate[i]) })

# With no transcendental in it, the same Newton iteration agrees bit for bit
# -- a cube root, written the same way, over the same anomalies:
cube = CArray.double(n)
CArray.jit_for(n) { |i|
  x = 1.0 + mean_anomaly[i].abs
  step = 1.0
  while step.abs > 1e-14 * x
    step = (x * x * x - (1.0 + mean_anomaly[i].abs)) / (3.0 * x * x)
    x = x - step
  end
  cube[i] = x
}
cube_in_ruby = CArray.double(n)
(0...n).each do |i|
  a = 1.0 + mean_anomaly[i].abs
  x = a
  step = 1.0
  while step.abs > 1e-14 * x
    step = (x * x * x - a) / (3.0 * x * x)
    x = x - step
  end
  cube_in_ruby[i] = x
end
puts "  a cube root by the same loop, bit for bit: #{cube.to_a == cube_in_ruby.to_a}"

# What it cost each way.  The kernel is compiled on its first call and cached,
# so the one above is what paid for it.
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
5.times { solve(mean_anomaly, eccentricity, tolerance) }
compiled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 5

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
(0...n).each do |i|
  guess = mean_anomaly[i]
  step = 1.0
  while step.abs > tolerance
    step = (guess - eccentricity * Math.sin(guess) - mean_anomaly[i]) /
           (1.0 - eccentricity * Math.cos(guess))
    guess = guess - step
  end
  in_ruby[i] = guess
end
interpreted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts
puts format("  %.2f ms compiled, %.2f ms in Ruby (%.0fx)",
            compiled * 1e3, interpreted * 1e3, interpreted / compiled)

# What `while` gives up is the guarantee that the loop ends.  Newton on this
# equation converges for every e < 1 from this starting guess, which is why it
# is written this way here; a solver for an equation with no such argument
# behind it wants the bounded spelling, where the extent holds the cap and a
# cell that ran out can be told from one that converged.  A kernel that does
# not return cannot be interrupted -- Ctrl-C is not delivered until the call
# comes back.
