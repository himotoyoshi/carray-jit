# What compiling costs, and how many elements it takes to pay for itself.
#
# The answer depends entirely on what is already cached, so all three states
# are measured rather than averaged: a kernel never compiled before, one
# compiled by an earlier process, and one already loaded in this one.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "tmpdir"
require "carray/jit"

SOURCE_TEMPLATE = <<~RUBY
  ->(i) {
    w  = x * values[i-1]
    wy = w - values[i-2]
    values[i] = wy + w - wy/%<tag>s
  }
RUBY

def compile_once (source, cache)
  ENV["CARRAY_JIT_CACHE"] = cache
  CArray::JIT.clear_registry
  Benchmark.realtime do
    CArray::JIT.compile(source,
                        array_names: [:values],
                        storage_types: { :values => "float64" },
                        scalar_values: { :x => 0.5 })
  end
end

Dir.mktmpdir do |cache|
  # A source nothing has ever compiled, so neither cache can hold it.
  cold_source = format(SOURCE_TEMPLATE, :tag => "(i + 7)")
  cold = compile_once(cold_source, cache)

  # The same kernel from a cleared registry: the object is on disk already.
  warm = compile_once(cold_source, cache)

  # And with the kernel still loaded in this process.
  repeat = Benchmark.realtime {
    CArray::JIT.compile(cold_source,
                        array_names: [:values],
                        storage_types: { :values => "float64" },
                        scalar_values: { :x => 0.5 })
  }

  # What the kernel saves per element, against the same loop in Ruby.
  length = 200_000
  x = 0.5
  values = CArray.double(length)
  values[0] = 1.0
  values[1] = x
  # Compile before timing: what is being measured here is the loop, not the
  # compiler -- the compiler is the other half of the table.
  CArray.jit_for(2...3) { |i|
    w  = x * values[i-1]
    wy = w - values[i-2]
    values[i] = wy + w - wy/i
  }
  jit = Benchmark.realtime {
    CArray.jit_for(2...length) { |i|
      w  = x * values[i-1]
      wy = w - values[i-2]
      values[i] = wy + w - wy/i
    }
  }
  plain = CArray.double(length)
  plain[0] = 1.0
  plain[1] = x
  ruby = Benchmark.realtime {
    (2...length).each do |i|
      w  = x * plain[i-1]
      wy = w - plain[i-2]
      plain[i] = wy + w - wy/i
    end
  }
  saved = (ruby - jit) / length

  puts format("compile, never seen before   %8.1f ms", cold * 1e3)
  puts format("  same kernel, new process   %8.1f ms   (the object is on disk)", warm * 1e3)
  puts format("  same kernel, same process  %8.3f ms   (already loaded)", repeat * 1e3)
  puts
  puts format("per element: Ruby %.1f ns, compiled %.1f ns, saved %.1f ns",
              ruby / length * 1e9, jit / length * 1e9, saved * 1e9)
  puts
  puts "pays for itself at:"
  [["never compiled before", cold],
   ["compiled by an earlier run", warm],
   ["already loaded", repeat]].each do |label, cost|
    puts format("  %-28s %10d elements", label, (cost / saved).ceil)
  end
end
