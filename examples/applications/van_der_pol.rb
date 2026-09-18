# An adaptive integrator, where the step size is the trajectory's own.
#
# The van der Pol oscillator is stiff in proportion to its parameter: at
# mu = 0.1 it is a gentle circle, at mu = 40 it spends most of the cycle
# crawling and the rest of it snapping across.  An integrator worth using
# answers that by changing its step -- taking it as long as the error allows,
# shortening it and *doing the step again* when the estimate comes back too
# large.
#
# Neither half of that survives an expression over whole arrays.  A fixed step
# can be written as an array pass, but then every trajectory pays the stiffest
# one's step count; and a rejected step -- this trajectory redoing what it
# just did while the others move on -- has no array spelling at all.  Here the
# step, the retry and the count belong to the cell.
#
# The method is Bogacki-Shampine 3(2): four stages, the third-order answer
# carried forward and the second-order one used to size the error.
#
#   ruby examples/applications/van_der_pol.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

TRAJECTORIES = 2_000
FINISH = 20.0
TOLERANCE = 1.0e-8
CAP = 200_000                           # a `while` in a kernel carries a bound

stiffness = CArray.double(TRAJECTORIES).seq!(0.1, 40.0 / TRAJECTORIES)
position = CArray.double(TRAJECTORIES)
velocity = CArray.double(TRAJECTORIES)
accepted = CArray.int32(TRAJECTORIES)
rejected = CArray.int32(TRAJECTORIES)

def integrate (stiffness, position, velocity, accepted, rejected)
  CArray.jit_for(stiffness.elements) { |i|
    mu = stiffness[i]
    x = 2.0                             # the trajectory starts out here
    v = 0.0
    t = 0.0
    step = 0.01
    taken = 0
    thrown = 0
    while t < FINISH && taken < CAP
      step = FINISH - t if t + step > FINISH

      k1x = v
      k1v = mu * (1.0 - x * x) * v - x
      x2 = x + 0.5 * step * k1x
      v2 = v + 0.5 * step * k1v
      k2x = v2
      k2v = mu * (1.0 - x2 * x2) * v2 - x2
      x3 = x + 0.75 * step * k2x
      v3 = v + 0.75 * step * k2v
      k3x = v3
      k3v = mu * (1.0 - x3 * x3) * v3 - x3
      nx = x + step * (2.0 * k1x + 3.0 * k2x + 4.0 * k3x) / 9.0
      nv = v + step * (2.0 * k1v + 3.0 * k2v + 4.0 * k3v) / 9.0
      k4x = nv
      k4v = mu * (1.0 - nx * nx) * nv - nx

      ex = step * (-5.0 * k1x / 72.0 + k2x / 12.0 + k3x / 9.0 - k4x / 8.0)
      ev = step * (-5.0 * k1v / 72.0 + k2v / 12.0 + k3v / 9.0 - k4v / 8.0)
      error = ex.abs > ev.abs ? ex.abs : ev.abs
      allowed = TOLERANCE * (1.0 + (nx.abs > nv.abs ? nx.abs : nv.abs))

      if error <= allowed
        t = t + step
        x = nx
        v = nv
        taken = taken + 1
      else
        # The step is not taken: this trajectory does it again, shorter,
        # while every other one carries on from wherever it is.
        thrown = thrown + 1
      end

      growth = 0.9 * Math.exp(Math.log(allowed / (error + 1.0e-300)) / 3.0)
      growth = 5.0 if growth > 5.0
      growth = 0.2 if growth < 0.2
      step = step * growth
    end
    position[i] = x
    velocity[i] = v
    accepted[i] = taken
    rejected[i] = thrown
  }
end

integrate(stiffness, position, velocity, accepted, rejected)

puts format("%d trajectories, mu from %.1f to %.1f, integrated to t = %.0f",
            TRAJECTORIES, stiffness[0], stiffness[TRAJECTORIES - 1], FINISH)
puts format("  steps taken      %d at the least, %d at the most, %.0f on average",
            accepted.min, accepted.max, accepted.mean)
puts format("  steps thrown away  up to %d on one trajectory", rejected.max)
puts format("  a fixed step would have to be the stiffest one's, so %d for everybody",
            accepted.max)
puts format("  which is %.1f times the work this did", accepted.max.to_f / accepted.mean)

# Against a reference: the same trajectory by fixed-step RK4, fine enough that
# it is the answer rather than another approximation.
def reference (mu, finish, steps)
  x = 2.0
  v = 0.0
  step = finish / steps
  steps.times do
    k1x = v;                  k1v = mu * (1.0 - x * x) * v - x
    ax = x + 0.5 * step * k1x; av = v + 0.5 * step * k1v
    k2x = av;                 k2v = mu * (1.0 - ax * ax) * av - ax
    bx = x + 0.5 * step * k2x; bv = v + 0.5 * step * k2v
    k3x = bv;                 k3v = mu * (1.0 - bx * bx) * bv - bx
    cx = x + step * k3x;      cv = v + step * k3v
    k4x = cv;                 k4v = mu * (1.0 - cx * cx) * cv - cx
    x += step * (k1x + 2 * k2x + 2 * k3x + k4x) / 6.0
    v += step * (k1v + 2 * k2v + 2 * k3v + k4v) / 6.0
  end
  x
end

puts
puts "     mu     here   reference        diff   steps"
[0, TRAJECTORIES / 2, TRAJECTORIES - 1].each do |i|
  exact = reference(stiffness[i], FINISH, 200_000)
  puts format("  %5.1f  %8.5f  %10.5f  %10.2e  %6d",
              stiffness[i], position[i], exact, (position[i] - exact).abs, accepted[i])
end

# Ruby does the same adaptive integration, over as many trajectories as is
# polite to wait for.
SAMPLE = 100

def integrate_in_ruby (stiffness, count)
  count.times.map do |i|
    mu = stiffness[i]
    x = 2.0
    v = 0.0
    t = 0.0
    step = 0.01
    taken = 0
    while t < FINISH && taken < CAP
      step = FINISH - t if t + step > FINISH
      k1x = v;                   k1v = mu * (1.0 - x * x) * v - x
      x2 = x + 0.5 * step * k1x; v2 = v + 0.5 * step * k1v
      k2x = v2;                  k2v = mu * (1.0 - x2 * x2) * v2 - x2
      x3 = x + 0.75 * step * k2x; v3 = v + 0.75 * step * k2v
      k3x = v3;                  k3v = mu * (1.0 - x3 * x3) * v3 - x3
      nx = x + step * (2.0 * k1x + 3.0 * k2x + 4.0 * k3x) / 9.0
      nv = v + step * (2.0 * k1v + 3.0 * k2v + 4.0 * k3v) / 9.0
      k4x = nv;                  k4v = mu * (1.0 - nx * nx) * nv - nx
      ex = step * (-5.0 * k1x / 72.0 + k2x / 12.0 + k3x / 9.0 - k4x / 8.0)
      ev = step * (-5.0 * k1v / 72.0 + k2v / 12.0 + k3v / 9.0 - k4v / 8.0)
      error = [ex.abs, ev.abs].max
      allowed = TOLERANCE * (1.0 + [nx.abs, nv.abs].max)
      if error <= allowed
        t += step
        x = nx
        v = nv
        taken += 1
      end
      growth = 0.9 * (allowed / (error + 1.0e-300)) ** (1.0 / 3.0)
      growth = 5.0 if growth > 5.0
      growth = 0.2 if growth < 0.2
      step *= growth
    end
    x
  end
end

in_ruby = integrate_in_ruby(stiffness, SAMPLE)
agree = (0...SAMPLE).all? { |i| (position[i] - in_ruby[i]).abs < 1.0e-12 }

def timed (repeats = 3)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

compiled = timed { integrate(stiffness, position, velocity, accepted, rejected) }
interpreted = timed(1) { integrate_in_ruby(stiffness, SAMPLE) }

puts
puts format("  agrees with the same integrator in Ruby  %s", agree)
puts format("  %6.0f ms here for %d trajectories, %6.0f ms in Ruby for %d (%.0fx a trajectory)",
            compiled * 1e3, TRAJECTORIES, interpreted * 1e3, SAMPLE,
            (interpreted / SAMPLE) / (compiled / TRAJECTORIES))
