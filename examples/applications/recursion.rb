# The classic recursive benchmarks, as compiled C functions.
#
# fib, tak, tarai and ackermann are what an interpreter is measured on, and
# none of them is an array computation: no cell, no extent, nothing to be
# element-wise about.  What they are is a scalar function calling itself,
# which is `jit_function`'s -- a body written in Ruby, compiled to C, and
# callable from Ruby or from a kernel.
#
# A declaration that gives a *name* puts that name in scope inside its own
# body, as C does, so the function can recurse.  The spelling is `.call`, the
# one every C function takes here, and that is what keeps the block runnable:
# the same block is the reference the compiled function is checked against.
#
# The parameters are the ones these benchmarks are usually quoted at, so the
# ratios below can be read beside anyone else's.
#
#   ruby examples/applications/recursion.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

fib = CArray.jit_function("int64_t fib(int64_t n)") { |n|
  n < 2 ? n : fib.call(n - 1) + fib.call(n - 2)
}

tak = CArray.jit_function("int64_t tak(int64_t x, int64_t y, int64_t z)") { |x, y, z|
  y < x ? tak.call(tak.call(x - 1, y, z),
                   tak.call(y - 1, z, x),
                   tak.call(z - 1, x, y)) : z
}

tarai = CArray.jit_function("int64_t tarai(int64_t x, int64_t y, int64_t z)") { |x, y, z|
  x <= y ? y : tarai.call(tarai.call(x - 1, y, z),
                          tarai.call(y - 1, z, x),
                          tarai.call(z - 1, x, y))
}

ack = CArray.jit_function("int64_t ack(int64_t m, int64_t n)") { |m, n|
  m == 0 ? n + 1 : (n == 0 ? ack.call(m - 1, 1) : ack.call(m - 1, ack.call(m, n - 1)))
}

# The same four in Ruby, which is both the answer to check against and the
# time to measure against.
def fib_rb (n) = n < 2 ? n : fib_rb(n - 1) + fib_rb(n - 2)
def tak_rb (x, y, z) = y < x ? tak_rb(tak_rb(x - 1, y, z), tak_rb(y - 1, z, x), tak_rb(z - 1, x, y)) : z
def tarai_rb (x, y, z) = x <= y ? y : tarai_rb(tarai_rb(x - 1, y, z), tarai_rb(y - 1, z, x), tarai_rb(z - 1, x, y))
def ack_rb (m, n) = m == 0 ? n + 1 : (n == 0 ? ack_rb(m - 1, 1) : ack_rb(m - 1, ack_rb(m, n - 1)))

def timed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  value = yield
  [value, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
end

CASES = [
  ["fib(34)",       -> (f) { f.call(34) },        -> { fib_rb(34) }],
  ["tak(18, 9, 0)", -> (f) { f.call(18, 9, 0) },  -> { tak_rb(18, 9, 0) }],
  ["tarai(12, 6, 0)", -> (f) { f.call(12, 6, 0) }, -> { tarai_rb(12, 6, 0) }],
  ["ack(3, 9)",     -> (f) { f.call(3, 9) },      -> { ack_rb(3, 9) }],
]

puts "a recursion compiled, and the same one interpreted"
[fib, tak, tarai, ack].zip(CASES) do |function, (name, compiled_call, ruby_call)|
  compiled_call.call(function)                      # compiled on the way in
  answer, took = timed { compiled_call.call(function) }
  in_ruby, ruby_took = timed { ruby_call.call }
  puts format("  %-16s %8d  %7.1f ms compiled  %7.1f ms in Ruby  (%4.0fx)  %s",
              name, answer, took * 1e3, ruby_took * 1e3, ruby_took / took,
              answer == in_ruby ? "agree" : "DIFFER")
end

# What the block is for
# ---------------------
# The function keeps the block it was written from, so the compiled recursion
# and the Ruby one are the same text and can be put side by side.  That is
# what makes "it means what Ruby means by it" checkable rather than argued.
puts
puts "  the block is still there: fib.block.call(20) = #{fib.block.call(20)}, " \
     "fib.call(20) = #{fib.call(20)}"

# Where a kernel comes in
# -----------------------
# A compiled function is not only faster to run, it is reachable per cell: the
# kernel calls the address directly, rather than crossing back into Ruby -- or
# into Fiddle, which costs a few hundred nanoseconds a cell, more than most of
# what it would be called for.
inputs = CArray.int64(24).seq!(1)
outputs = CArray.int64(24)

CArray.jit_for(24) { |i| outputs[i] = fib.call(inputs[i]) }

puts
puts "fib over an array, one call per cell"
puts "  #{outputs[0..11].to_a.inspect}"
puts "  matches Ruby            #{outputs.to_a == inputs.to_a.map { |n| fib_rb(n) }}"

_, per_cell = timed { CArray.jit_for(24) { |i| outputs[i] = fib.call(inputs[i]) } }
_, in_ruby = timed { inputs.to_a.map { |n| fib_rb(n) } }
puts format("  the pass: %.1f ms compiled, %.1f ms in Ruby (%.0fx)",
            per_cell * 1e3, in_ruby * 1e3, in_ruby / per_cell)

# What is not on offer
# --------------------
# An anonymous declaration -- the function-pointer type -- has nothing to call
# itself by, which is C's position too: it is the name in the declaration that
# is put in scope inside the body, and `int64_t (*)(int64_t)` has none.  The
# `f` below is then an ordinary Ruby local seen from inside, which is a
# capture, and a capture is what a compiled function does not get.
begin
  f = CArray.jit_function("int64_t (*)(int64_t)") { |n|
    n < 2 ? n : f.call(n - 1) + f.call(n - 2)
  }
rescue CArray::JIT::Unsupported => error
  puts
  puts "an anonymous declaration"
  puts "  #{error.message.sub(/ \(at line.*/m, "")}"
end

# And nothing here stops a recursion running out of stack: a compiled function
# that goes too deep is a SIGSEGV, not a SystemStackError.  That is C's
# bargain, taken knowingly -- the same one the `while` loop in a kernel takes.
