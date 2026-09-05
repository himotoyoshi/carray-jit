# Raising from a kernel.
#
# A kernel can stop and say why.  What comes back is a RuntimeError with the
# message written in the block -- what `raise "..."` gives in Ruby -- and the
# loop stops where it raised: the cell that raised is not written, and neither
# are the ones after it.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

n = 8
depth = CArray.double(n).seq!(3.0, -1.0)          # 3 2 1 0 -1 -2 ...
out = CArray.double(n).fill(-99.0)

begin
  CArray.jit_for(n) { |i|
    raise "depth went negative" if depth[i] < 0.0
    out[i] = Math.sqrt(depth[i])
  }
rescue RuntimeError => error
  puts "raising"
  puts "  class                 #{error.class}"
  puts "  message               #{error.message}"
end

# The cells before the raise keep what the kernel wrote, as they do when a
# division with no divisor stops one.
puts "  written before it     #{out.to_a[0, 4].map { |e| e.round(3) }.inspect}"
puts "  untouched after it    #{out.to_a[4..].all?(-99.0)}"

# The message is written out and the class is not named, and both follow from
# where the message goes: C has nothing to carry a string out of a cell in, so
# the message is registered as the kernel is compiled and the cell writes a
# code for it into the error slot the kernel already watches.  The raise
# itself happens once the loop has stopped and there is a Ruby stack to raise
# on.

# A cell whose value is missing does not raise: the comparison was decided by
# bytes that mean nothing, and this is the rule the division helper already
# keeps and that `if` keeps for what it writes.
holed = CArray.double(4).seq!(1.0)
holed[2] = 999.0          # a value that would raise below
holed[2] = UNDEF          # marked missing; the bytes are left alone
squares = CArray.double(4)
CArray.jit_for(4) { |i|
  raise "out of range" if holed[i] > 100.0
  squares[i] = holed[i] * holed[i]
}
puts "  a masked cell         did not raise on its 999.0; #{squares.count_masked} cell came back missing"

# A jit_function body raises the same way, and the message travels with the
# function: f.call(-1.0) and the same body reached from a kernel raise the
# same thing.
safe_sqrt = CArray.jit_function("double (*)(double)") { |x|
  raise "negative argument" if x < 0.0
  Math.sqrt(x)
}

begin
  safe_sqrt.call(-1.0)
rescue RuntimeError => error
  puts "  from jit_function     #{error.message} (called from Ruby)"
end

begin
  CArray.jit_for(n) { |i| out[i] = safe_sqrt.call(depth[i]) }
rescue RuntimeError => error
  puts "  from a kernel         #{error.message} (the same message, pasted in)"
end
