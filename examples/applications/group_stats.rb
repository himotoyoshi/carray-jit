# Aggregating by a label, when the aggregate is not a sum.
#
# Two million readings, each tagged with the station it came from, and the
# question is what each station did.  Counting them and adding them up are
# what `CArray#bincount` is for and it is very good at it -- a pass over the
# labels and a pass over the weights, in C, and nothing here beats that.
#
# The rest is the problem.  A maximum per station, the reading where that
# maximum happened, how many readings passed a threshold: none of those is a
# sum, and an array expression has no way to say "add this cell to the slot
# its label names, and only if it is larger than what is there".  So the
# whole-array answer is a pass per label -- select the label's cells, reduce
# them, repeat -- and the cost is the number of labels times the size of the
# data, no matter how few cells each label owns.
#
# A kernel says it the way it is meant: one walk, and each cell updates the
# slot its label names.
#
#   ruby examples/applications/group_stats.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

READINGS = 2_000_000
STATIONS = 64

random = CArray::Rng.new(seed: 20260913)

# Stations of very different sizes: the square of a uniform draw lands most
# of the readings on the low-numbered ones.
station = CArray.double(READINGS)
station.random!(rng: random)
station = ((station ** 2) * STATIONS).int32

value = CArray.double(READINGS)
value.random!(rng: random)
value = value * 40.0

LIMIT = 35.0

count = CArray.int64(STATIONS)
total = CArray.double(STATIONS)
peak = CArray.double(STATIONS).fill(-Float::INFINITY)
peak_at = CArray.int64(STATIONS).fill(-1)
exceed = CArray.int64(STATIONS)

def summarise (station, value, count, total, peak, peak_at, exceed)
  count.fill(0)
  total.fill(0.0)
  peak.fill(-Float::INFINITY)
  peak_at.fill(-1)
  exceed.fill(0)
  CArray.jit_for(station.elements) { |i|
    k = station[i]
    v = value[i]
    count[k] += 1
    total[k] += v
    exceed[k] += 1 if v > LIMIT
    if v > peak[k]
      peak[k] = v
      peak_at[k] = i
    end
  }
end

summarise(station, value, count, total, peak, peak_at, exceed)

puts format("%d readings over %d stations", READINGS, STATIONS)
puts "  station   count      mean     peak   at reading   over #{LIMIT.to_i}"
[0, 1, 2, STATIONS / 2, STATIONS - 1].each do |k|
  puts format("  %7d %7d %9.3f %8.3f %12d %8d",
              k, count[k], total[k] / count[k], peak[k], peak_at[k], exceed[k])
end

# Every one of those is checkable by selecting the station's cells, which is
# also the whole-array way of computing it in the first place.
k = 1
cells = value[station.eq(k)]
puts
puts format("  station %d checks out  %s", k,
            [count[k], peak[k], exceed[k]] ==
            [cells.elements, cells.max, cells.gt(LIMIT).count(1)])

# What the sum and the count cost when CArray does them, which is the part of
# this a kernel has no business replacing.
def timed (repeats = 5)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

binned = timed { station.bincount(length: STATIONS)
                 station.bincount(weights: value, length: STATIONS) }

# The maximum per station, over whole arrays: one selection and one reduction
# per station.  The readings are walked STATIONS times over.
by_masks = timed(1) {
  STATIONS.times.map { |label| value[station.eq(label)].max }
}

everything = timed {
  summarise(station, value, count, total, peak, peak_at, exceed)
}

puts
puts format("  count and sum, CArray#bincount     %6.1f ms", binned * 1e3)
puts format("  the maximum alone, by selection    %6.1f ms", by_masks * 1e3)
puts format("  all five in one walk, this kernel  %6.1f ms   %.0fx",
            everything * 1e3, by_masks / everything)

# Which is the shape of it: bincount walks the data twice whatever the labels
# are, the selections walk it once per label, and the kernel walks it once.
puts
puts format("  readings walked -- bincount %d, selections %d, kernel %d",
            READINGS * 2, READINGS * STATIONS, READINGS)
