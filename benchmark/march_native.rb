# What naming the machine would buy a kernel.
#
# Compiler::FLAGS names no -march, so a kernel is built for whatever the
# compiler targets by default: on x86_64 that is the baseline -- SSE2, two
# doubles to a vector -- while on arm64 NEON is the baseline and is there
# either way.  So x86 may be leaving AVX2 unused where arm64 is already at
# its native width.  This measures whether that is worth anything.
#
# The flag is not edited into the gem.  CARRAY_JIT_CC names the compiler, so
# a wrapper that appends the flag is enough, and it keys its own cache
# entries: the compiler's path is part of the digest, so the two builds
# cannot be confused for each other.
#
# The two are measured alternately rather than one after the other, because
# a machine drifts -- it warms up, and something else starts -- and a drift
# spread over one whole configuration reads as a difference between them.
# The recurrence is the control: it is one dependent chain and cannot be
# vectorised, so whatever it reports is what the method cannot tell apart.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "fileutils"
require "tmpdir"
require "rbconfig"
require "carray/jit"

ROUNDS = 9
REPEATS = 16          # calls per sample, so a sample is long enough to trust

N = 4_000_000
SIDE = 2_000
ROWS = 2_000
COLUMNS = 2_000

def median (values)
  sorted = values.sort
  sorted[sorted.size / 2]
end

# A compiler that adds the flag, so nothing in the gem has to be edited.
def wrapper_for (flag, directory, real)
  path = File.join(directory, "cc-#{flag.delete('^a-zA-Z0-9')}")
  File.write(path, "#!/bin/sh\nexec #{real} \"$@\" #{flag}\n")
  FileUtils.chmod(0755, path)
  path
end

def accepts? (compiler, directory)
  source = File.join(directory, "probe.c")
  File.write(source, "int probe(void) { return 0; }\n")
  system(compiler, "-c", source, "-o", File.join(directory, "probe.o"),
         :out => File::NULL, :err => File::NULL)
end

a = CArray.float64(N) { |i| (i % 1000) * 0.001 + 0.5 }
b = CArray.float64(N) { |i| (i % 997) * 0.001 + 0.5 }
out = CArray.float64(N)

grid = CArray.float64(SIDE, SIDE) { |i, j| (i + j) % 100 * 0.01 }
next_grid = CArray.float64(SIDE, SIDE)

chain = CArray.float64(N) { |i| (i % 13) * 0.01 }

matrix = CArray.float64(ROWS, COLUMNS) { |i, j| (i + j) % 100 * 0.01 }
totals = CArray.float64(ROWS)

KERNELS = {
  "element-wise, compute-bound" =>
    -> { CArray.jit_each { out = Math.sqrt(a * a + b * b) * 0.5 + a / (b + 1.0) } },
  "stencil, bandwidth-bound" =>
    -> { CArray.jit_for(1...(SIDE - 1), 1...(SIDE - 1)) { |i, j|
           next_grid[i, j] = (grid[i-1, j] + grid[i+1, j] +
                              grid[i, j-1] + grid[i, j+1]) * 0.25
         } },
  "reduction, eight partial sums" =>
    -> { CArray.jit_for(ROWS) { |i|
           accumulator = 0.0
           (0...COLUMNS).each { |j| accumulator = accumulator + matrix[i, j] }
           totals[i] = accumulator
         } },
  "recurrence, serial (control)" =>
    -> { CArray.jit_for(1...N) { |i| chain[i] = chain[i-1] * 0.5 + a[i] } },
}

def configure (cache, compiler)
  ENV["CARRAY_JIT_CACHE"] = cache
  ENV["CARRAY_JIT_CC"] = compiler
  CArray::JIT.clear_registry
end

def sample
  Benchmark.realtime { REPEATS.times { yield } }
end

FLAG = ARGV.first || "-march=native"

Dir.mktmpdir("march-native-") do |directory|
  real = ENV["CARRAY_JIT_CC"] || RbConfig::CONFIG["CC"] || "cc"
  flagged = wrapper_for(FLAG, directory, real)

  unless accepts?(flagged, directory)
    abort "#{real} will not take #{FLAG} -- name another flag as the argument"
  end

  configurations = {
    :default => [File.join(directory, "base"), real],
    FLAG.to_sym => [File.join(directory, "flagged"), flagged],
  }

  configurations.each_value do |cache, compiler|      # warm both caches
    configure(cache, compiler)
    KERNELS.each_value { |kernel| kernel.call }
  end

  samples = Hash.new { |all, label| all[label] = Hash.new { |one, k| one[k] = [] } }
  ROUNDS.times do
    configurations.each do |name, (cache, compiler)|
      configure(cache, compiler)
      KERNELS.each { |label, kernel| samples[label][name] << sample(&kernel) }
    end
  end

  puts "#{RbConfig::CONFIG['arch']}, #{real}, median of #{ROUNDS}, " \
       "#{REPEATS} calls each"
  puts
  puts format("%-32s %11s %14s %8s", "", "default", FLAG, "ratio")
  KERNELS.each_key do |label|
    base = median(samples[label][:default]) / REPEATS
    flag = median(samples[label][FLAG.to_sym]) / REPEATS
    puts format("%-32s %8.2f ms %11.2f ms %7.2fx",
                label, base * 1e3, flag * 1e3, base / flag)
  end
  puts
  puts "A ratio above 1 is what naming the machine bought.  Read the three"
  puts "against the recurrence, which cannot be vectorised: whatever it"
  puts "reports is the noise floor of this run."
end
