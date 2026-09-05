# Quality control on a sensor record with gaps
#
# Real measurements have holes in them, and CArray already has a mask to say
# where.  What is awkward in a loop is that the rules refer to the holes: fill
# a gap of one sample from its neighbours, drop a spike, and take the daily
# mean only from the days that have enough readings left.
#
# `reading[i] == UNDEF` is how you ask in Ruby, and it means the same inside a
# kernel -- it reads the mask, not the value, so what the branch writes is not
# itself masked.  That is what makes filling a hole possible at all.
#
#   ruby examples/applications/sensor_gaps.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

days, hours = 30, 24
random = Random.new(20260902)

# Hourly temperature: a daily cycle, a seasonal drift, and noise.
reading = CArray.double(days, hours) { |d, h|
  15.0 + 8.0 * Math.sin((h - 9) * Math::PI / 12) + d * 0.1 +
    random.rand(-1.0..1.0)
}

# The logger dropped some samples, and once reported a spike.
dropped = 0
days.times do |d|
  hours.times do |h|
    if random.rand < 0.06
      reading[d, h] = UNDEF
      dropped += 1
    end
  end
end
reading[7, 13] = 71.4
reading[19, 3] = -40.0

# And on day 12 it was offline from midnight until noon.
(0..12).each { |h| reading[12, h] = UNDEF }
dropped = reading.count_masked

puts "#{days} days x #{hours} hours, #{dropped} samples missing"

# 1. Reject physically impossible readings.  Writing UNDEF marks the cell
#    missing and leaves its value alone.
rejected = CArray.int32(1)
CArray.jit_for(days, hours) { |d, h|
  if reading[d, h] > 50.0
    reading[d, h] = UNDEF
  elsif reading[d, h] < -30.0
    reading[d, h] = UNDEF
  end
}
puts "  #{reading.count_masked - dropped} readings rejected as out of range"

# 2. Fill a hole from its neighbours, but only where both neighbours are there.
#    Where they are not, the average reads a masked cell and the result comes
#    out masked by itself -- the rule does not have to be written twice.
filled = CArray.double(days, hours)
CArray.jit_for(days, 1...(hours-1)) { |d, h|
  if reading[d, h] == UNDEF
    filled[d, h] = 0.5 * (reading[d, h-1] + reading[d, h+1])
  else
    filled[d, h] = reading[d, h]
  end
}
filled[nil, 0] = reading[nil, 0]
filled[nil, hours-1] = reading[nil, hours-1]

recovered = reading.count_masked - filled.count_masked
puts "  #{recovered} holes interpolated, #{filled.count_masked} still missing"

# 3. The daily mean, from the readings that survived -- and a day with fewer
#    than twenty valid hours does not get a mean at all.
mean = CArray.double(days)
valid = CArray.int32(days)
CArray.jit_for(days) { |d|
  total = 0.0
  count = 0
  (0...hours).each { |h|
    if filled[d, h] == UNDEF
      count = count
    else
      total = total + filled[d, h]
      count = count + 1
    end
  }
  valid[d] = count
  if count >= 20
    mean[d] = total / count
  else
    mean[d] = UNDEF
  end
}

puts "  #{mean.count_masked} of #{days} days rejected for too few readings"
puts
puts "  day  valid  mean"
(0...days).each do |d|
  next unless d < 6 || d > days - 4 || valid[d] < 20
  text = mean[d] == UNDEF ? "  --  " : format("%6.2f", mean[d])
  bar = mean[d] == UNDEF ? "" : "#" * ((mean[d] - 10) * 2).round
  puts format("  %3d  %5d  %s  %s", d, valid[d], text, bar)
end

# The same rules written as a Ruby loop, for comparison -- and to check that
# they agree, which is possible precisely because the kernel asks about the
# mask rather than relying on it propagating.
reference = Array.new(days) do |d|
  values = (0...hours).map { |h| filled[d, h] == UNDEF ? nil : filled[d, h] }.compact
  values.size >= 20 ? values.sum / values.size : nil
end
agrees = (0...days).all? { |d|
  reference[d].nil? ? mean[d] == UNDEF : (mean[d] - reference[d]).abs < 1e-12
}
puts
puts "  agrees with the same rules written in Ruby: #{agrees}"
