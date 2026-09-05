# Complex arrays: cmplx64 and cmplx128, computed in `double _Complex`.
#
# The interesting part is not that it works but what it costs to make the
# answer Ruby's rather than C's: Ruby's Complex arithmetic differs from the C
# operators in the last bit and in the sign of a zero, so three of the four
# operators are compiled to match Ruby rather than to match C.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

n = 8
# A spiral, so that the magnitude has something to say.
signal = CArray.cmplx128(n) { |i|
  Complex(Math.cos(i * 0.7), Math.sin(i * 0.7)) * (1.0 + 0.25 * i)
}

# Arithmetic, a captured Complex scalar, and an imaginary literal.
rotation = Complex(0.0, 1.0)
rotated = CArray.cmplx128(n)
CArray.jit_for(n) { |i| rotated[i] = signal[i] * rotation + 0.5i }

reference = (0...n).map { |i| signal[i] * rotation + 0.5i }
puts "complex arithmetic"
puts "  matches Ruby      #{(0...n).all? { |i| rotated[i] == reference[i] }}"

# The way out of the complex type.  `abs`, `real`, `imag` and `arg` hand back
# a Float, which is what lets a complex kernel write into a real array;
# `conjugate` stays complex.
power = CArray.double(n)
phase = CArray.double(n)
CArray.jit_for(n) { |i| power[i] = signal[i].abs }
CArray.jit_for(n) { |i| phase[i] = signal[i].arg }
puts "  power             #{power.to_a.map { |e| e.round(4) }.inspect}"
puts "  phase             #{phase.to_a.map { |e| e.round(4) }.inspect}"

# And the way in, from two real arrays.
real = CArray.double(n).seq!(1.0)
imaginary = CArray.double(n).seq!(0.0, 0.25)
built = CArray.cmplx128(n)
CArray.jit_for(n) { |i| built[i] = Complex(real[i], imaginary[i]) }
puts "  built from parts  #{built.to_a.first(3).inspect}"

# The fifteen functions a complex CArray answers compile to their C99
# c-prefixed forms.  Which fifteen is CArray's list, not a list invented here,
# so a formula gives the same answer whichever way it is applied.
transformed = CArray.cmplx128(n)
CArray.jit_for(n) { |i| transformed[i] = signal[i].tanh }
puts "  tanh matches the array operator #{transformed.to_a == signal.tanh.to_a}"

# A reduction over complex cells: the accumulator starts from a complex zero.
total = CArray.cmplx128(1)
CArray.jit_for(1) { |i|
  running = Complex(0.0, 0.0)
  (0...n).each { |j| running = running + signal[j] }
  total[i] = running
}
serial = (0...n).inject(Complex(0.0, 0.0)) { |sum, j| sum + signal[j] }
puts "  sum               #{total[0].rectangular.map { |e| e.round(6) }.inspect}"
puts "  matches Ruby      #{total[0] == serial}"

# Where Ruby and C part company.  A real operand carries an exact Integer zero
# as its imaginary part, and Ruby's own arithmetic returns the other operand
# untouched rather than combining with it -- so the sign of a zero survives an
# addition that C's `+` would flatten.
edge = CArray.cmplx128(1)
edge[0] = Complex(1.0, -0.0)
kept = CArray.cmplx128(1)
CArray.jit_for(1) { |i| kept[i] = edge[i] + 2.0 }
puts
puts "signed zeros"
puts "  Ruby              #{(Complex(1.0, -0.0) + 2.0)}"
puts "  the kernel        #{kept[0]}"
puts "  widening first    #{Complex(1.0, -0.0) + Complex(2.0, 0.0)}   <- what C's + would give"

# `**` is the one operation whose answer is not the Ruby loop's to the last
# bit: Ruby raises a Complex to a power by binary powering, cpow goes round
# through exp and log.  A few machine epsilons apart, growing with the
# exponent -- and `z * z` is both exact and cheaper than the library call.
cubed = CArray.cmplx128(n)
CArray.jit_for(n) { |i| cubed[i] = signal[i] ** 3 }
worst = (0...n).map { |i| e = signal[i] ** 3; (cubed[i] - e).abs / e.abs }.max

squared = CArray.cmplx128(n)
CArray.jit_for(n) { |i| squared[i] = signal[i] * signal[i] }

puts
puts "the one inexact operation"
puts "  z ** 3 worst      #{(worst / Float::EPSILON).round(1)} machine epsilons"
puts "  z * z  matches Ruby exactly #{(0...n).all? { |i| squared[i] == signal[i] * signal[i] }}"

# What is refused on a Complex is what Ruby refuses, and nothing else: the
# ordering comparisons, `%`, the rounding methods and the bit operators.
puts
puts "refused, as Ruby refuses them"
[["->(i) { power[i] = signal[i] < 1.0 ? 1.0 : 0.0 }",
  proc { CArray.jit_for(n) { |i| power[i] = signal[i] < 1.0 ? 1.0 : 0.0 } }],
 ["->(i) { power[i] = signal[i].floor }",
  proc { CArray.jit_for(n) { |i| power[i] = signal[i].floor } }],
 ["->(i) { power[i] = signal[i] }",
  proc { CArray.jit_for(n) { |i| power[i] = signal[i] } }]].each do |written, run|
  begin
    run.call
  rescue CArray::JIT::Unsupported => error
    puts "  #{written}"
    puts "    #{error.message.sub(/ \(at line.*/, '')}"
  end
end
