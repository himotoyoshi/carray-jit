# An alarm with hysteresis, which is a state machine over a series.
#
# A threshold on its own chatters: a reading sitting on the line flips the
# alarm on and off every sample.  So an alarm is written with two thresholds
# and a dwell -- it raises only after the reading has been above the high
# line for a while, and clears only after it has been below the low line for
# a while -- and what it does at any sample depends on what it was doing at
# the sample before.
#
# That is the part arrays have no answer for.  `a.gt(HIGH)` is a pass, and so
# is a running sum, but neither can say "raise only if we were not already
# raised, and only if the run of exceedances reaching this sample is long
# enough, where that run was reset by the last reading that was not one".
# The state is carried, the carry is not a sum, and CArray has no operation
# that composes it.  So this is ordinarily a Ruby loop over every sample, and
# the samples are usually many.
#
#   ruby examples/applications/alarm.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

SAMPLES = 2_000_000
HIGH = 70.0                             # raise above this
LOW = 60.0                              # and clear below this
DWELL = 5                               # after this many in a row

# A series that wanders across both lines, with noise sitting on them.
random = CArray::Rng.new(seed: 20260913)
noise = CArray.double(SAMPLES)
noise.random!(rng: random)
reading = CArray.double(SAMPLES)
CArray.jit_for(SAMPLES) { |i|
  slow = 64.0 + 12.0 * Math.sin(i / 90000.0) + 4.0 * Math.sin(i / 700.0)
  reading[i] = slow + 6.0 * (noise[i] - 0.5)
}

state = CArray.int8(SAMPLES)

# The machine's state, as the four things it remembers.  A `CScalar` is a
# value with a home, so it is still there on the next iteration -- which is
# what makes it the carry a state machine needs, and what a local cannot be.
raised = CScalar.int8()
above = CScalar.int32()
below = CScalar.int32()
episodes = CScalar.int64()

def alarm (reading, state, raised, above, below, episodes)
  raised[] = 0
  above[] = 0
  below[] = 0
  episodes[] = 0
  CArray.jit_for(reading.elements) { |i|
    value = reading[i]
    above[] = value > HIGH ? above[] + 1 : 0
    below[] = value < LOW ? below[] + 1 : 0
    if raised[] == 0 && above[] >= DWELL
      raised[] = 1
      episodes[] += 1
    elsif raised[] == 1 && below[] >= DWELL
      raised[] = 0
    end
    state[i] = raised[]
  }
end

alarm(reading, state, raised, above, below, episodes)

# What it found.
up = state.eq(1).count(1)
puts format("%d samples, %.1f%% of them above %.0f", SAMPLES,
            100.0 * reading.gt(HIGH).count(1) / SAMPLES, HIGH)
puts format("  alarm raised %d times, and was up for %.1f%% of the record",
            episodes[0], 100.0 * up / SAMPLES)

# A plain threshold, for the contrast: the same record, no hysteresis and no
# dwell, which is what an array expression can say.
plain = reading.gt(HIGH).int8
plain_flips = plain[1..-1].ne(plain[0..-2]).count(1)
state_flips = state[1..-1].ne(state[0..-2]).count(1)
puts format("  a bare threshold changes its mind %d times; this alarm, %d",
            plain_flips, state_flips)

# The same loop in Ruby.
def alarm_in_ruby (reading)
  values = reading.to_a
  state = Array.new(values.size, 0)
  raised = 0
  above = 0
  below = 0
  episodes = 0
  values.each_with_index do |value, i|
    above = value > HIGH ? above + 1 : 0
    below = value < LOW ? below + 1 : 0
    if raised == 0 && above >= DWELL
      raised = 1
      episodes += 1
    elsif raised == 1 && below >= DWELL
      raised = 0
    end
    state[i] = raised
  end
  [state, episodes]
end

in_ruby, ruby_episodes = alarm_in_ruby(reading)
puts format("  agrees with the same loop in Ruby  %s",
            state.to_a == in_ruby && episodes[0] == ruby_episodes)

def timed (repeats = 3)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

compiled = timed { alarm(reading, state, raised, above, below, episodes) }
interpreted = timed(1) { alarm_in_ruby(reading) }

puts
puts format("  %6.1f ms compiled, %6.0f ms in Ruby (%.0fx)",
            compiled * 1e3, interpreted * 1e3, interpreted / compiled)
