# Smoothing a time series, and measuring the drawdown
#
# These are the calculations CArray's operators cannot help with, because each
# value depends on the one before it: an exponential moving average, a running
# peak, the drawdown from that peak.  There is no way to write them as an
# expression over whole arrays -- so ordinarily you write a Ruby loop and pay
# for a block call per sample.
#
#   ruby examples/applications/moving_average.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

n = 500_000
random = Random.new(20260902)

# A price series: a multiplicative random walk with a slow drift.
price = CArray.double(n)
value = 100.0
n.times do |i|
  value *= 1.0 + random.rand(-0.004..0.004) + 0.000002 * Math.sin(i / 5000.0)
  price[i] = value
end

alpha = 0.02
smoothed = CArray.double(n)
peak = CArray.double(n)
drawdown = CArray.double(n)

smoothed[0] = price[0]
peak[0] = price[0]

# Exponential moving average.  One line, and the dependency on the previous
# cell is exactly what the extent's direction records.
CArray.jit_for(1...n) { |i|
  smoothed[i] = alpha * price[i] + (1.0 - alpha) * smoothed[i-1]
}

# The running peak and the drawdown from it -- a branch per cell, which is
# also why this is not an expression over arrays.
CArray.jit_for(1...n) { |i|
  if price[i] > peak[i-1]
    peak[i] = price[i]
  else
    peak[i] = peak[i-1]
  end
  drawdown[i] = (price[i] - peak[i]) / peak[i]
}

worst = drawdown.min
puts "#{n} samples"
puts format("  last price      %.2f", price[n-1])
puts format("  smoothed        %.2f", smoothed[n-1])
puts format("  worst drawdown  %.2f%%  at sample %d", worst * 100, (drawdown.eq(worst)).where[0])

# A rolling mean, as a cumulative sum and its own difference `window` cells
# back.  The window is an ordinary local: an offset may be an integer the
# block closed over, and it reaches the kernel as an argument, so changing the
# window does not compile anything again.
window = 200
cumulative = CArray.double(n)
rolling = CArray.double(n)
cumulative[0] = price[0]
CArray.jit_for(1...n) { |i| cumulative[i] = cumulative[i-1] + price[i] }
CArray.jit_for(window...n) { |i|
  rolling[i] = (cumulative[i] - cumulative[i - window]) / window
}
puts format("  rolling(%d)     %.2f", window, rolling[n-1])

# The same three calculations as the Ruby loops they replace.
def ruby_versions (price, alpha, n)
  smoothed = Array.new(n, 0.0)
  peak = Array.new(n, 0.0)
  drawdown = Array.new(n, 0.0)
  smoothed[0] = price[0]
  peak[0] = price[0]
  (1...n).each do |i|
    smoothed[i] = alpha * price[i] + (1.0 - alpha) * smoothed[i-1]
    peak[i] = price[i] > peak[i-1] ? price[i] : peak[i-1]
    drawdown[i] = (price[i] - peak[i]) / peak[i]
  end
  [smoothed, peak, drawdown]
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
reference_smoothed, _, reference_drawdown = ruby_versions(price, alpha, n)
interpreted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
CArray.jit_for(1...n) { |i|
  smoothed[i] = alpha * price[i] + (1.0 - alpha) * smoothed[i-1]
}
CArray.jit_for(1...n) { |i|
  if price[i] > peak[i-1]
    peak[i] = price[i]
  else
    peak[i] = peak[i-1]
  end
  drawdown[i] = (price[i] - peak[i]) / peak[i]
}
compiled = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts format("  %.1f ms in Ruby, %.1f ms compiled (%.0fx)",
            interpreted * 1e3, compiled * 1e3, interpreted / compiled)
puts "  same answers to the last bit: #{smoothed.to_a == reference_smoothed &&
                                        drawdown.to_a == reference_drawdown}"

# The series and its moving average, sampled at a hundred points.
puts
low, high = price.min, price.max
levels = 14
scale = ->(v) { ((v - low) / (high - low) * levels).round }
raw = (0...100).map { |k| price[k * (n / 100)] }
ema = (0...100).map { |k| smoothed[k * (n / 100)] }
levels.downto(0) do |level|
  row = (0...100).map { |k|
    if scale.(ema[k]) == level then "-"
    elsif scale.(raw[k]) == level then "."
    else " "
    end
  }
  puts "  " + row.join
end
puts "  price ., moving average -"
