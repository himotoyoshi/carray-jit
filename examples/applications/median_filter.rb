# Despiking a series with a median, and where a cell keeps its scratch.
#
# A mean is ruined by one bad sample; a median is not, which is why a median
# filter is what a record with spikes in it gets.  The window has to be
# ordered to find its middle, and ordering a window is the thing an array
# expression has no operation for: CArray can sort an array, but not the nine
# cells around every cell, separately, a million times.
#
# So this is three spellings of one answer -- Ruby's, a kernel that sorts the
# window in a workspace, and a kernel that finds the middle with comparisons
# alone -- and they agree to the bit.  What separates them is where the cell's
# scratch lives.  A workspace indexed by the cell is memory: a million rows of
# nine, written and read on every comparison.  A local is a register.  It is
# the same lesson every other kernel here quietly relies on, and this is where
# it is worth a hundred times.
#
#   ruby examples/applications/median_filter.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

SAMPLES = 1_000_000
WINDOW = 9
HALF = WINDOW / 2

# A smooth signal, some noise, and a spike every few hundred samples.
random = CArray::Rng.new(seed: 20260913)
noise = CArray.double(SAMPLES)
noise.random!(rng: random)
chance = CArray.double(SAMPLES)
chance.random!(rng: random)
signal = CArray.double(SAMPLES)
clean = CArray.double(SAMPLES)
CArray.jit_for(SAMPLES) { |i|
  smooth = 10.0 * Math.sin(i / 5000.0) + 0.5 * (noise[i] - 0.5)
  clean[i] = smooth
  signal[i] = chance[i] < 0.002 ? smooth + 40.0 * (chance[i] * 500.0 - 0.5) : smooth
}

sorted_out = CArray.double(SAMPLES)
network_out = CArray.double(SAMPLES)

# One: the window copied into the cell's own row of a workspace and put in
# order there.  Straightforward, and every comparison is a memory access.
workspace = CArray.double(SAMPLES, WINDOW)

def by_sorting (signal, out, workspace)
  n = signal.elements
  CArray.jit_for(HALF...(n - HALF)) { |i|
    k = 0
    while k < WINDOW
      workspace[i, k] = signal[i - HALF + k]
      k = k + 1
    end
    k = 1
    while k < WINDOW
      value = workspace[i, k]
      j = k - 1
      while j >= 0 && workspace[i, j] > value
        workspace[i, j + 1] = workspace[i, j]
        j = j - 1
      end
      workspace[i, j + 1] = value
      k = k + 1
    end
    out[i] = workspace[i, HALF]
  }
end

# Two: the median of nine by comparisons alone.  Order each group of three,
# then take the largest of the three smallest, the middle of the middles and
# the smallest of the largests, and the median of those three is the median
# of the nine.  Nineteen comparisons, and nothing leaves a register.
def by_network (signal, out)
  n = signal.elements
  CArray.jit_for(HALF...(n - HALF)) { |i|
    a = signal[i - 4]; b = signal[i - 3]; c = signal[i - 2]
    d = signal[i - 1]; e = signal[i];     f = signal[i + 1]
    g = signal[i + 2]; h = signal[i + 3]; k = signal[i + 4]

    lo = a < b ? a : b; hi = a < b ? b : a
    mid = hi < c ? hi : c
    m1 = lo > mid ? lo : mid
    l1 = lo < c ? lo : c
    h1 = hi > c ? hi : c

    lo = d < e ? d : e; hi = d < e ? e : d
    mid = hi < f ? hi : f
    m2 = lo > mid ? lo : mid
    l2 = lo < f ? lo : f
    h2 = hi > f ? hi : f

    lo = g < h ? g : h; hi = g < h ? h : g
    mid = hi < k ? hi : k
    m3 = lo > mid ? lo : mid
    l3 = lo < k ? lo : k
    h3 = hi > k ? hi : k

    largest_small = l1 > l2 ? l1 : l2
    largest_small = largest_small > l3 ? largest_small : l3
    smallest_large = h1 < h2 ? h1 : h2
    smallest_large = smallest_large < h3 ? smallest_large : h3

    lo = m1 < m2 ? m1 : m2; hi = m1 < m2 ? m2 : m1
    mid = hi < m3 ? hi : m3
    middle_middle = lo > mid ? lo : mid

    lo = largest_small < middle_middle ? largest_small : middle_middle
    hi = largest_small < middle_middle ? middle_middle : largest_small
    mid = hi < smallest_large ? hi : smallest_large
    out[i] = lo > mid ? lo : mid
  }
end

by_sorting(signal, sorted_out, workspace)
by_network(signal, network_out)

# And Ruby's, which is what this would otherwise be.
def in_ruby (signal)
  signal.to_a.each_cons(WINDOW).map { |window| window.sort[HALF] }
end

reference = in_ruby(signal)
inner = HALF...(SAMPLES - HALF)
puts format("%d samples, window of %d", SAMPLES, WINDOW)
puts format("  the sorted kernel agrees with Ruby   %s",
            inner.all? { |i| sorted_out[i] == reference[i - HALF] })
puts format("  the network kernel agrees with Ruby  %s",
            inner.all? { |i| network_out[i] == reference[i - HALF] })

puts format("  %d spikes went in; the worst departure from the clean signal was %.2f, and is now %.2f",
            chance.lt(0.002).count(1),
            (signal[inner] - clean[inner]).abs.max,
            (network_out[inner] - clean[inner]).abs.max)

def timed (repeats = 3)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  repeats.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / repeats
end

sorting = timed { by_sorting(signal, sorted_out, workspace) }
network = timed { by_network(signal, network_out) }
interpreted = timed(1) { in_ruby(signal) }

puts
puts format("  Ruby, sorting each window            %7.0f ms", interpreted * 1e3)
puts format("  kernel, sorting in a workspace       %7.0f ms   %.0fx",
            sorting * 1e3, interpreted / sorting)
puts format("  kernel, comparisons in registers     %7.0f ms   %.0fx",
            network * 1e3, interpreted / network)
puts format("  the workspace is %d x %d doubles, which is %.0f MB the other one never touches",
            SAMPLES, WINDOW, SAMPLES * WINDOW * 8 / 1048576.0)
