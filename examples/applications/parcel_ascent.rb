# Lifting a parcel up a sounding: CAPE, CIN, and where the cloud starts.
#
# Take the air at the ground and lift it.  It cools one way while it is dry
# and another way once it has condensed, and the pressure where it switches
# -- the lifting condensation level -- is not a constant: it is worked out
# from that column's temperature and dew point.  Above it the parcel follows
# a moist adiabat, which has no closed form and is integrated step by step,
# each step starting from where the last one ended.  Whether the parcel is
# warmer than the air around it decides whether that layer adds to the
# convective available potential energy or to the inhibition, and the level
# where the sign first turns positive -- the level of free convection -- is
# itself discovered on the way up.
#
# There is no expression over whole arrays for any of that.  The state is
# carried up the column, the equation changes partway at a level each column
# picks for itself, and what a layer contributes depends on something that is
# not known until the walk reaches it.  So a sounding is climbed in a loop,
# one column at a time, and that is exactly what a kernel is.
#
# The physics is the textbook version: Bolton's LCL, a pseudoadiabat
# integrated in pressure, and buoyancy from temperature rather than virtual
# temperature.  Enough to be recognisable, not a substitute for a library.
#
#   ruby examples/applications/parcel_ascent.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

RD = 287.05                             # J/kg/K, dry air
CPD = 1005.7                            # J/kg/K
LV = 2.501e6                            # J/kg, vaporisation
EPS = 0.622                             # molecular weight ratio
KAPPA = 0.2854                          # Rd/cp

LEVELS = 91                             # 1000 hPa to 100 hPa, every 10
COLUMNS = 4_000                         # soundings to climb
SUBSTEPS = 4                            # moist steps between two levels

pressure = CArray.double(LEVELS).seq!(1000.0, -10.0)

# Synthetic soundings: a lapse rate of 6.5 K/km over a surface that varies
# from column to column, isothermal above the tropopause.
random = CArray::Rng.new(seed: 20260913)
surface = CArray.double(COLUMNS)
surface.random!(rng: random)
surface = surface * 12.0 + 22.0 + 273.15               # 22 to 34 degC
spread = CArray.double(COLUMNS)
spread.random!(rng: random)
spread = spread * 14.0 + 2.0                           # dew point depression

environment = CArray.double(COLUMNS, LEVELS)
height = CArray.double(LEVELS)
LEVELS.times { |k| height[k] = 44330.0 * (1.0 - (pressure[k] / 1013.25) ** 0.1903) }
CArray.jit_for(COLUMNS, LEVELS) { |c, k|
  lapsed = surface[c] - 0.0065 * height[k]
  environment[c, k] = lapsed < 216.65 ? 216.65 : lapsed
}
dewpoint = environment[nil, 0] - spread

cape = CArray.double(COLUMNS)
cin = CArray.double(COLUMNS)
lcl = CArray.double(COLUMNS)
lfc = CArray.double(COLUMNS)
el = CArray.double(COLUMNS)

def climb (pressure, environment, dewpoint, cape, cin, lcl, lfc, el)
  columns, levels = environment.dim
  CArray.jit_for(columns) { |c|
    base = pressure[0]
    start = environment[c, 0]
    dew = dewpoint[c] < start ? dewpoint[c] : start

    # Bolton (1980): the temperature the parcel reaches when it saturates,
    # and the pressure that goes with it along the dry adiabat.
    saturating = 1.0 / (1.0 / (dew - 56.0) + Math.log(start / dew) / 800.0) + 56.0
    condensation = base * Math.exp(Math.log(saturating / start) / KAPPA)
    lcl[c] = condensation

    parcel = start
    at = base
    positive = 0.0
    pending = 0.0                       # negative area, until an LFC claims it
    free = -1.0
    equilibrium = -1.0

    k = 1
    while k < levels
      target = pressure[k]
      # Lift to this level, in at most two goes: dry as far as the
      # condensation level, moist from there on.
      while at > target + 1.0e-9
        stop = at > condensation && condensation > target ? condensation : target
        if at > condensation - 1.0e-9
          parcel = start * Math.exp(KAPPA * Math.log(stop / base))
          at = stop
        else
          step = (stop - at) / SUBSTEPS
          n = 0
          while n < SUBSTEPS
            celsius = parcel - 273.15
            saturation = 6.112 * Math.exp(17.67 * celsius / (celsius + 243.5))
            mixing = EPS * saturation / (at - saturation)
            numerator = RD * parcel + LV * mixing
            denominator = CPD + (LV * LV * mixing * EPS) / (RD * parcel * parcel)
            parcel = parcel + (numerator / denominator) * step / at
            at = at + step
            n = n + 1
          end
        end
      end

      # What this layer is worth.
      excess = parcel - environment[c, k]
      layer = RD * excess * Math.log(pressure[k - 1] / pressure[k])
      if excess > 0.0
        free = pressure[k] if free < 0.0
        positive = positive + layer
        equilibrium = pressure[k]
      elsif free < 0.0
        # Below the level of free convection, so this layer is what the
        # parcel has to be pushed through: inhibition, not energy.
        pending = pending + layer
      end
      k = k + 1
    end

    cape[c] = positive
    cin[c] = free < 0.0 ? 0.0 : pending
    lfc[c] = free
    el[c] = equilibrium
  }
end

climb(pressure, environment, dewpoint, cape, cin, lcl, lfc, el)

puts format("%d soundings, %d levels each", COLUMNS, LEVELS)
puts "   T    Td      LCL     LFC      EL     CAPE      CIN"
[0, 1, 2, 3, 4].each do |c|
  puts format("  %4.1f  %4.1f   %6.1f  %6.1f  %6.1f  %7.1f  %7.1f",
              environment[c, 0] - 273.15, dewpoint[c] - 273.15,
              lcl[c], lfc[c], el[c], cape[c], cin[c])
end

# What has to hold if the climb was a climb.
reached = lfc.gt(0.0)
puts
puts format("  %d of %d columns reached a level of free convection", reached.count(1), COLUMNS)
puts format("  the LFC is never below the LCL   %s",
            (lfc[reached] - lcl[reached]).max <= 0.0)
puts format("  the EL is never below the LFC    %s",
            (el[reached] - lfc[reached]).max <= 0.0)
puts format("  CAPE is zero exactly where there is no LFC  %s",
            cape[reached.not].max == 0.0)
puts format("  strongest column: CAPE %.0f J/kg with CIN %.0f J/kg",
            cape.max, cin[cape.max_addr])

# The same climb in Ruby.
def climb_in_ruby (pressure, environment, dewpoint)
  columns, levels = environment.dim
  levels_a = pressure.to_a
  cape = Array.new(columns, 0.0)
  columns.times do |c|
    base = levels_a[0]
    start = environment[c, 0]
    dew = [dewpoint[c], start].min
    saturating = 1.0 / (1.0 / (dew - 56.0) + Math.log(start / dew) / 800.0) + 56.0
    condensation = base * Math.exp(Math.log(saturating / start) / KAPPA)
    parcel = start
    at = base
    positive = 0.0
    free = -1.0
    (1...levels).each do |k|
      target = levels_a[k]
      while at > target + 1.0e-9
        stop = at > condensation && condensation > target ? condensation : target
        if at > condensation - 1.0e-9
          parcel = start * Math.exp(KAPPA * Math.log(stop / base))
          at = stop
        else
          step = (stop - at) / SUBSTEPS
          SUBSTEPS.times do
            celsius = parcel - 273.15
            saturation = 6.112 * Math.exp(17.67 * celsius / (celsius + 243.5))
            mixing = EPS * saturation / (at - saturation)
            numerator = RD * parcel + LV * mixing
            denominator = CPD + (LV * LV * mixing * EPS) / (RD * parcel * parcel)
            parcel += (numerator / denominator) * step / at
            at += step
          end
        end
      end
      excess = parcel - environment[c, k]
      if excess > 0.0
        free = levels_a[k] if free < 0.0
        positive += RD * excess * Math.log(levels_a[k - 1] / levels_a[k])
      end
    end
    cape[c] = positive
  end
  cape
end

in_ruby = climb_in_ruby(pressure, environment, dewpoint)
agree = (0...COLUMNS).all? { |c| (cape[c] - in_ruby[c]).abs < 1.0e-9 }
puts format("  agrees with the same climb in Ruby  %s", agree)

def timed (repeats = 3)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

compiled = timed { climb(pressure, environment, dewpoint, cape, cin, lcl, lfc, el) }
interpreted = timed(1) { climb_in_ruby(pressure, environment, dewpoint) }

puts
puts format("  %6.1f ms compiled, %6.0f ms in Ruby (%.0fx)",
            compiled * 1e3, interpreted * 1e3, interpreted / compiled)
puts format("  each column: %d levels, a condensation level of its own, and %d moist steps above it",
            LEVELS, SUBSTEPS)
