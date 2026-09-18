# A derived field on a weather grid, where one of the fields needs solving.
#
# Temperature and relative humidity come off a grid -- a GRIB message, a
# netCDF variable, a model's output -- and what is wanted is something else.
# The dew point is an expression: saturation vapour pressure, the actual
# vapour pressure from the humidity, and Magnus inverted.  Written over whole
# arrays that is four passes and three temporaries the size of the grid;
# written as a kernel it is one pass and none, which is the ordinary reason
# to use one.
#
# The wet-bulb temperature is the other kind.  It is defined by the
# psychrometric equation, which has no closed form, so every cell solves its
# own -- and how many Newton steps that takes depends on how far the cell's
# dew point is from its answer, which is the cell's own business.  The
# whole-array route can still be written, because a fixed number of rounds
# covers the worst cell; what it cannot do is let a cell that has converged
# stop, so every cell pays the worst one's count, and each round is a pass
# over the grid holding another grid.
#
#   ruby examples/applications/wet_bulb.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

ROWS, COLUMNS = 721, 1440               # a quarter-degree global grid
PRESSURE = 1013.25                      # hPa, one level
TOLERANCE = 1.0e-6                      # degrees, how close is close enough
CAP = 50                                # a `while` in a kernel takes a cap

# Stand-ins for the fields that would have been read: a pole-to-pole
# temperature gradient with a wave in it, and humidity that varies across it.
temperature = CArray.double(ROWS, COLUMNS)
humidity = CArray.double(ROWS, COLUMNS)
CArray.jit_for(ROWS, COLUMNS) { |j, i|
  latitude = 90.0 - 180.0 * j / (ROWS - 1)
  temperature[j, i] = 30.0 - 55.0 * (latitude / 90.0).abs +
                      4.0 * Math.sin(i / 40.0) * Math.cos(latitude / 25.0)
  humidity[j, i] = 35.0 + 60.0 * (0.5 + 0.5 * Math.cos(i / 30.0 + j / 60.0))
}

dew_point = CArray.double(ROWS, COLUMNS)
wet_bulb = CArray.double(ROWS, COLUMNS)
rounds_taken = CArray.int8(ROWS, COLUMNS)

# Everything in one walk.  `vapour` and `gamma` are the cell's own values and
# never become arrays; `low` and `high` are the cell's bracket, which is why
# the loop can end when this cell is done rather than when the last one is.
def derive (temperature, humidity, dew_point, wet_bulb, rounds_taken)
  rows, columns = temperature.dim
  CArray.jit_for(rows, columns) { |j, i|
    air = temperature[j, i]
    saturation = 6.112 * Math.exp(17.67 * air / (air + 243.5))
    vapour = saturation * humidity[j, i] / 100.0
    gamma = Math.log(vapour / 6.112)
    dew = 243.5 * gamma / (17.67 - gamma)
    dew_point[j, i] = dew

    # Newton on the psychrometric equation, started from the dew point.  The
    # cap is not decoration: a `while` in a kernel has no interpreter to
    # interrupt it, so a solver carries the bound it is allowed.
    guess = dew
    step = 1.0
    taken = 0
    while step.abs > TOLERANCE && taken < CAP
      saturated = 6.112 * Math.exp(17.67 * guess / (guess + 243.5))
      residual = saturated - 0.000665 * PRESSURE * (air - guess) - vapour
      slope = saturated * 17.67 * 243.5 / ((guess + 243.5) * (guess + 243.5)) +
              0.000665 * PRESSURE
      step = residual / slope
      guess = guess - step
      taken = taken + 1
    end
    wet_bulb[j, i] = guess
    rounds_taken[j, i] = taken
  }
end

derive(temperature, humidity, dew_point, wet_bulb, rounds_taken)

puts format("%d x %d grid, %d cells", ROWS, COLUMNS, ROWS * COLUMNS)
puts "       T     RH       Td       Tw"
[[180, 0], [360, 200], [360, 720], [540, 1000], [700, 30]].each do |j, i|
  puts format("  %6.2f %6.1f %8.2f %8.2f",
              temperature[j, i], humidity[j, i], dew_point[j, i], wet_bulb[j, i])
end
puts format("  the wet bulb is never above the air temperature  %s",
            (wet_bulb - temperature).max <= 0.0)
puts format("  and never below the dew point                    %s",
            (wet_bulb - dew_point).min >= -TOLERANCE)

# The part an expression cannot have: the cells did not agree on how long
# this took.
puts
puts format("Newton steps per cell: %d at the least, %d at the most, %.2f on average",
            rounds_taken.min, rounds_taken.max, rounds_taken.mean)

# The same bisection over whole arrays.  It cannot stop per cell, so it runs
# the worst cell's count everywhere, and every line here is a pass over the
# grid holding another grid.
def derive_over_arrays (temperature, humidity, rounds)
  saturation = (temperature * 17.67 / (temperature + 243.5)).exp * 6.112
  vapour = saturation * humidity / 100.0
  gamma = (vapour / 6.112).log
  dew = gamma * 243.5 / (17.67 - gamma)
  guess = dew.to_ca
  rounds.times do
    saturated = (guess * 17.67 / (guess + 243.5)).exp * 6.112
    residual = saturated - (temperature - guess) * (0.000665 * PRESSURE) - vapour
    slope = saturated * (17.67 * 243.5) / ((guess + 243.5) * (guess + 243.5)) +
            0.000665 * PRESSURE
    guess = guess - residual / slope
  end
  [dew, guess]
end

rounds = rounds_taken.max
array_dew, array_wet = derive_over_arrays(temperature, humidity, rounds)
puts format("  over whole arrays, everyone pays %d rounds", rounds)
puts format("  and agrees with the kernel to %.1e  %s", TOLERANCE,
            (array_wet - wet_bulb).abs.max < TOLERANCE)

def timed (repeats = 3)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

compiled = timed { derive(temperature, humidity, dew_point, wet_bulb, rounds_taken) }
whole = timed { derive_over_arrays(temperature, humidity, rounds) }

puts
puts format("  one kernel      %7.0f ms", compiled * 1e3)
puts format("  whole arrays    %7.0f ms   %.1fx", whole * 1e3, whole / compiled)
puts format("  %.2f Newton steps a cell here, %d for every cell there", rounds_taken.mean, rounds)
# Each array operation in `derive_over_arrays` is its own walk over the grid
# and its own array to hold the answer -- sixteen of them per round, counted
# off the expression -- where the kernel walks the grid once and holds the
# cell's `guess` in a register.
puts format("  the grid is %.1f MB, and the array route builds %d of those and walks the grid %d times",
            ROWS * COLUMNS * 8 / 1048576.0, 16 * rounds, 16 * rounds)
