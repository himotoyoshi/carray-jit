# Letting CArray drive the loop.
#
# An element-wise pass is the one shape that is a *sweep*: nothing reaches a
# neighbour, nothing chooses an order.  So where this CArray has
# `ca_call_cslab` (3.0.1 and later), jit_each hands it the compiled body
# and lets it acquire the operands -- broadcasting them, ORing and propagating
# the masks, and calling back a chunk at a time.
#
# Nothing about the expression changes, and nothing here is written
# differently.  What changes is who opens the arrays, and what that costs.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"
require "benchmark"

Sweep = CArray::JIT::Sweep
Access = CArray::JIT::Access

puts "this CArray has ca_call_cslab: #{Sweep.available?}"
puts

# The rank leaves the loop
# ------------------------
# A chunk is one flat run of cells -- and CArray's acquire reads an operand's
# element count and element size and never looks at its shape, so a chunk is
# already flat.  Nothing is reshaped.  What is compiled flat is the *kernel*.

def doubled (source, out)
  CArray.jit_each { out = source * 2.0 }
end

flat_in = CArray.double(6).seq!
flat_out = CArray.double(6)
cube_in = CArray.double(2, 3, 4).seq!
cube_out = CArray.double(2, 3, 4)

flat = doubled(flat_in, flat_out)
cube = doubled(cube_in, cube_out)

puts "one block, a run of cells and a cube of them"
puts "  loop axes            #{flat.rank} and #{cube.rank}"
puts "  arrays keep shape    #{flat_out.dim.inspect} and #{cube_out.dim.inspect}"
puts "  one compiled kernel  #{flat.equal?(cube)}"
puts "  answers              #{flat_out.to_a == (flat_in * 2.0).to_a} and " \
     "#{cube_out.to_a == (cube_in * 2.0).to_a}"
puts

# The wrapper is a call, not a second code generator: the kernel's first three
# arguments are already base, stride and bounds, which is what a chunk arrives
# as.
puts "the sweep entry point"
puts flat.slab_source.lines
       .grep(/^carray_jit_slab|bounds\[1\] = n|carray_jit_kernel\(base/)
       .map { |line| "  " + line.strip }
puts

# What it is worth
# ----------------
# An operand CArray cannot walk in place -- a gather, a lazy array -- is
# re-gathered 32KB at a time by the sweep.  The tiers here move the whole box
# the kernel touches instead, and for an element-wise pass that box is the
# whole array.

n = 2_000_000
src = CArray.double(n).seq!
b = CArray.double(n).seq!(0.5, 0.5)
out = CArray.double(n)
gather = src[CArray.int32(n).seq.reverse]

def timed
  2.times { yield }
  Benchmark.realtime { 3.times { yield } } / 3
end

puts "n = #{n}, out[] = x + b * 2.0"
[["entity", src], ["gather view", gather]].each do |label, x|
  elapsed = timed { CArray.jit_each { out = x + b * 2.0 } }
  scratch = Access.classify(x)[:tier] == 3 ? "%.0f MB" % (n * 8.0 / 1024 / 1024) : "none"
  puts "  %-12s tier %d   %6.2f ms   the driver here would hold %s" %
       [label, Access.classify(x)[:tier], elapsed * 1e3, scratch]
end
puts "  -- the sweep holds 32 KB per gathered operand, whatever n is."

# A strided view is the case where the re-gather buys nothing: the tiers
# address a column, a transpose or every other cell in place, so there is no
# whole-array copy to be saved from.  That is why the driver is chosen on the
# operands and not only on the shape.
half = (0...n).step(2)
strided_x, strided_b, strided_out = src[half], b[half], out[half]
elapsed = timed { CArray.jit_each { strided_out = strided_x + strided_b * 2.0 } }
puts "  %-12s tier %d   %6.2f ms   %.2f ns/cell, and no scratch either way" %
     ["strided view", Access.classify(strided_x)[:tier], elapsed * 1e3,
      elapsed * 1e9 / strided_x.elements]
puts "  -- swept, the same pass was 4.7 ns/cell: re-gathered for nothing."
puts

# What keeps the driver here
# --------------------------
# Four things, and only the last is about this CArray being old.

columns = CArray.double(64, 64).seq!
into = CArray.double(64, 64)
every_other = columns[nil, (0...64).step(2)]
every_other_out = into[nil, (0...64).step(2)]
kernel = CArray.jit_each { every_other_out = every_other * 2.0 }
puts "a strided view operand   loop axes #{kernel.rank}"
puts "  -- walked in place here, re-gathered there for nothing."

matrix = CArray.double(3, 4).seq!
row = CArray.double(1, 4).seq!(10.0)
stretched = CArray.double(3, 4)
kernel = CArray.jit_each { stretched = matrix * row }
puts "a stretched operand      loop axes #{kernel.rank}"
puts "  -- broadcasting arrives as a stride of zero on an axis, and a flat"
puts "     run has no axes, so cell k would stop lining up."

masked = CArray.double(5).seq!(1.0)
masked[2] = UNDEF
masked_out = CArray.double(5)
kernel = CArray.jit_each { masked_out = masked * 2.0 }
puts "a mask anywhere in the pass     sweepable? #{kernel.sweepable?}"
puts "  -- an operand that carries one, or a body that asks about one."
puts "     CArray ORs and propagates the masks, but `a[i] == UNDEF` is a"
puts "     question about a single cell, and a chunk carries no per-cell"
puts "     mask to ask it of.  The answer is the same either way:"
puts "     #{masked_out.is_masked.to_a.inspect}"
puts
puts "a CArray without the family     asked for by symbol, not assumed;"
puts "  -- an older one falls back without the caller hearing about it."
puts

# jit_for never goes this way, and that is not a limitation: a kernel that
# names an index reaches neighbours, chooses an order and runs inner loops,
# none of which a chunked walk can offer.  Splitting the two methods by what
# the block names drew the same line as what a sweep can drive.
recurrence = CArray.double(8).seq!(1.0)
CArray.jit_for(1...8) { |i| recurrence[i] = recurrence[i-1] * 1.5 }
puts "jit_for stays here by its nature"
puts "  #{recurrence.to_a.map { |v| v.round(4) }.inspect}"
