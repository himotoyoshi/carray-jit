# C functions in a kernel: the ones already compiled, and the ones written
# here.
#
# math.h is already handled -- `Math.sqrt(x)` compiles to `sqrt(x)` and the
# compiler can inline it.  This is for everything else: the Bessel functions
# in libm that Ruby has no Math method for, and, the same way, anything in a
# library you can dlopen.
#
# Two methods, because they do two different things.  `jit_extern` finds one
# someone else compiled -- `extern` is C's word for a body that lives
# elsewhere, and finding it is Fiddle's job, with no compiler involved.
# `jit_function` compiles a body of your own.  What comes back is the same
# kind of object either way, so a kernel calls it without knowing which it is.
#
# The *call* is not Fiddle's, either way: reaching a function through
# Fiddle::Function costs a few hundred nanoseconds per cell, which is more
# than the arithmetic it was called for.  Fiddle is asked where the function
# is; the kernel calls it.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"
require "benchmark"

# The prototype is what you would copy out of the header.  With no `from:`,
# the symbol is looked for in what the process has already loaded, which is
# where libm's own functions are.
j0 = CArray.jit_extern("double j0(double)")
puts "bound: #{j0}"

x = CArray.double(6).seq!(1.0)
out = CArray.double(6)

CArray.jit_each { out = j0.call(x) }
puts "j0(x)         #{out.to_a.map { |v| v.round(6) }.inspect}"
puts "same in Ruby  #{x.to_a.map { |v| j0.call(v).round(6) }.inspect}"
puts

# What "apply f to an array" cannot say
# -------------------------------------
# A stencil needs the function at two places at once.  There is no array of
# intermediate results to hold them, so this is not expressible as a map --
# but it is an ordinary kernel.

smoothed = CArray.double(6)
CArray.jit_for(1...6) { |i| smoothed[i] = 0.5 * (j0.call(x[i]) + j0.call(x[i-1])) }
puts "half-sum of neighbouring j0"
puts "  #{smoothed[1..5].to_a.map { |v| v.round(6) }.inspect}"
puts

# It mixes into an expression like anything else, and takes as many arguments
# as the prototype says.
atan2 = CArray.jit_extern("double atan2(double, double)")
y = CArray.double(6).seq!(0.5, 0.5)
mixed = CArray.double(6)
CArray.jit_each { mixed = atan2.call(x, y) * 2.0 - j0.call(x) }
puts "atan2(x, y) * 2 - j0(x)"
puts "  #{mixed.to_a.map { |v| v.round(6) }.inspect}"
puts

# One kernel, every function of that shape
# ----------------------------------------
# The kernel is compiled for the *signature*, not the symbol: the address
# travels in a buffer beside the captured scalars rather than being linked
# against.  So the block below is compiled once and serves all three, and
# nothing in the generated C says which library any of them came from.

def apply (f, x, out)
  CArray.jit_each { out = f.call(x) }
end

kernels = ["double j0(double)", "double y0(double)", "double tgamma(double)"]
            .map { |prototype|
  f = CArray.jit_extern(prototype)
  kernel = apply(f, x, out)
  puts "  %-24s -> %s" % [prototype, out[0..2].to_a.map { |v| v.round(6) }.inspect]
  kernel
}
puts "compiled kernels: #{kernels.uniq.size} for #{kernels.size} functions"
puts

puts kernels.first.c_source.lines.grep(/typedef|functions\[0\]/).map(&:strip).uniq
puts

# A function of your own
# ----------------------
# `jit_function`: the same C declaration, written anonymously.
# `double (*)(double)` is the spelling C already has for the type of a
# function pointer, which is what this hands out.  There is no name because
# nothing links by name -- the address travels in a buffer -- so a name would
# have been invented to be looked at once.

smoothstep = CArray.jit_function("double (*)(double)") { |t|
  clamped = t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t)
  clamped * clamped * (3.0 - 2.0 * clamped)
}
puts "declared: #{smoothstep}"

# It keeps its block, so what the kernel runs and what Ruby computes can be
# put side by side.  They agree to the last bit; that is the whole claim of
# this compiler, and here it is checkable rather than argued.
[-0.5, 0.25, 0.5, 2.0].each do |v|
  puts "  smoothstep(%5s)  C %.17g   Ruby %.17g" %
       [v, smoothstep.call(v), smoothstep.block.call(v)]
end
puts

# And it is called from a kernel like any other, which is what gives kernels
# something they did not have: a body you can factor and name.
w = CArray.double(6).seq!(-0.2, 0.3)
blended = CArray.double(6)
low = CArray.double(6) { 10.0 }
high = CArray.double(6) { 20.0 }
CArray.jit_each {
  blended = low + (high - low) * smoothstep.call(w)
}
puts "blend across a ramp"
puts "  #{blended.to_a.map { |v| v.round(4) }.inspect}"
puts

# Calling itself
# --------------
# A declaration that gives a name puts that name in scope inside its own body,
# which is what C does, so the function can recurse.  The spelling is `.call`,
# the one every C function takes here, and that is not a compromise: it keeps
# the block runnable, so the compiled recursion and the Ruby one can be put
# side by side.

fact = CArray.jit_function("double fact(double)") { |n|
  n <= 1.0 ? 1.0 : n * fact.call(n - 1.0)
}
puts "5! compiled C  #{fact.call(5.0)}"
puts "   same block in Ruby  #{fact.block.call(5.0)}"
puts fact.c_source.lines.grep(/carray_jit_fact/).map { |line| "  #{line.strip}" }
puts "  -- `fact` in the block is a spelling; the call goes to the qualified"
puts "     symbol, so it cannot reach anything else named fact."
puts

# A pointer parameter is handed on the way C hands one on, so a recursion can
# walk an array.
total = CArray.jit_function("double total(int n, const double v[8])") { |n, v|
  n == 0 ? 0.0 : v[n - 1] + total.call(n - 1, v)
}
values = CArray.double(8).seq!(1.0)
puts "sum of #{values.to_a.map(&:to_i).inspect} by recursion  #{total.call(8, values)}"
puts "  matches Ruby  #{total.call(8, values) == total.block.call(8, values)}"
puts

# Dividing by zero
# ----------------
# `6 % 0` raises in Ruby, and a kernel raises it too -- it is handed somewhere
# to report.  A compiled function has only the signature its declaration gave
# it, so the object carries a place of its own: one exported int the division
# helpers write into, declared only when the body can reach it.  The C still
# returns a number and touches no Ruby value; `call` is what looks afterwards.

remainder = CArray.jit_function("int r(int a, int b)") { |a, b| a % b }
puts "7 % 3   C #{remainder.call(7, 3)}   Ruby #{remainder.block.call(7, 3)}"
[[remainder, 7, 0]].each do |f, a, b|
  compiled = begin; f.call(a, b); rescue => error; "#{error.class}: #{error.message}"; end
  in_ruby  = begin; f.block.call(a, b); rescue => error; "#{error.class}: #{error.message}"; end
  puts "7 % 0   C #{compiled}"
  puts "        Ruby #{in_ruby}"
end
puts remainder.c_source.lines.grep(/carray_jit_error/).map { |line| "  #{line.strip}" }

# A float division is not that case -- an infinity is the answer in Ruby, in C
# and here -- so a body that only divides floats declares no flag.
float_divide = CArray.jit_function("double d(double a, double b)") { |a, b| a / b }
puts "1.0 / 0.0  #{float_divide.call(1.0, 0.0)}, and no flag: " \
     "#{!float_divide.c_source.include?("carray_jit_error")}"
puts

# Handing one back out
# --------------------
# The compiled object references no Ruby symbol at all, so the address is safe
# to call from a library that knows nothing about Ruby -- and gsl_function is
# `double (*)(double x, void *params)`, which is written here exactly as GSL's
# own documentation writes it.  The body may not read the pointer: it is a
# slot the ABI requires, not a value.

integrand = CArray.jit_function("double (*)(double x, void *params)") { |x, params|
  Math.exp(-x * x)
}
puts "for a gsl_function slot: #{integrand}"
puts "  pointer: 0x#{integrand.pointer.to_i.to_s(16)}"
puts

# Coefficients from outside, without capturing them
# ------------------------------------------------
# A compiled function reaches nothing outside its parameters, so what it needs
# arrives as one -- which is what C does anyway, and C's declarator says the
# rest: `const` is the read/write distinction, and a length is a length.

poly = CArray.jit_function("double (*)(double x, const double coef[3])") { |x, c|
  c[0] + c[1] * x + c[2] * x * x
}
coef = CArray.double(3) { |i| [1.0, 2.0, 3.0][i] }
puts "1 + 2x + 3x^2 at x = 2"
puts "  compiled C  #{poly.call(2.0, coef)}"
puts "  same block in Ruby  #{poly.block.call(2.0, coef)}"
puts "  -- `coef[0]` means the same to a CArray as to a C pointer, so the"
puts "     body is unchanged between them."
puts

# The whole ODE signature is sayable, with no half of it invented here.
ode = CArray.jit_function(
  "int (*)(double t, const double y[2], double dydt[2], void *params)"
) { |t, y, dydt, params|
  dydt[0] = y[1]
  dydt[1] = -y[0]
  0
}
state = CArray.double(2) { |i| [1.0, 0.0][i] }
derivative = CArray.double(2)
ode.call(0.0, state, derivative, nil)
puts "harmonic oscillator: y = #{state.to_a.inspect} -> dy/dt = #{derivative.to_a.inspect}"
puts ode.c_source.lines.last(6).join

# ...and a kernel can hand over one of its own arrays
# ---------------------------------------------------
# `x[i]` is a cell and `coef` is the whole array.  Which is meant comes from
# the declaration rather than from the spelling.

ramp = CArray.double(6).seq!(0.0, 0.5)
fitted = CArray.double(6)
CArray.jit_for(6) { |i| fitted[i] = poly.call(ramp[i], coef) }
puts "1 + 2x + 3x^2 along a ramp"
puts "  #{fitted.to_a.map { |v| v.round(4) }.inspect}"
puts "  matches Ruby  #{fitted.to_a == ramp.to_a.map { |v| poly.block.call(v, coef) }}"
puts

# What it costs
# -------------
# Against the two things a Ruby user can do today: call it through Fiddle one
# cell at a time, or find a Math method that happens to exist.

n = 200_000
big = CArray.double(n).seq!(1.0, 1e-5)
big_out = CArray.double(n)
gamma = CArray.jit_extern("double tgamma(double)")

def timed
  2.times { yield }
  Benchmark.realtime { 3.times { yield } } / 3
end

compiled = timed { CArray.jit_each { big_out = gamma.call(big) } }
values = big.to_a
jit_for_fiddle = timed { values.map { |v| gamma.call(v) } }
ruby_math = timed { values.map { |v| Math.gamma(v) } }

puts "tgamma over #{n} cells"
puts "  in the kernel      %7.2f ms  %7.1f ns/element" %
     [compiled * 1e3, compiled / n * 1e9]
puts "  Fiddle, per cell   %7.2f ms  %7.1f ns/element  %.0fx" %
     [jit_for_fiddle * 1e3, jit_for_fiddle / n * 1e9, jit_for_fiddle / compiled]
puts "  Math.gamma map     %7.2f ms  %7.1f ns/element  %.0fx" %
     [ruby_math * 1e3, ruby_math / n * 1e9, ruby_math / compiled]
puts
puts "-- and Ruby has no Math method for j0 at all."
