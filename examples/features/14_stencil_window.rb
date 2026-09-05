# The window spelling of a stencil, and the border as an argument.
#
# 02_stencil.rb writes the same five-point average with the indices named.
# What that spelling has nowhere to put is the edge: `src[i-1, j]` at i = 0
# has no meaning, so the extents avoid it and the border keeps whatever the
# output array held.  A window has no index to write and so has somewhere to
# put the question -- `border:` at the call.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

rows, columns = 5, 6
src = CArray.double(rows, columns).seq!(1.0)

# The block's parameters are windows onto the arrays given, in that order:
# a[0, 0] is the cell the loop is on, a[-1, 0] its neighbour.  The block's
# value is what the cell gets, as jit_map's is, and an array of the same shape
# comes back.
smoothed = CArray.jit_stencil(src) { |a|
  0.25 * (a[-1, 0] + a[1, 0] + a[0, -1] + a[0, 1])
}

# The same stencil with the indices named, over the interior alone.
written = CArray.double(rows, columns)
CArray.jit_for(1...(rows-1), 1...(columns-1)) { |i, j|
  written[i, j] = 0.25 * (src[i-1, j] + src[i+1, j] + src[i, j-1] + src[i, j+1])
}

puts "the window"
puts "  interior matches jit_for   #{smoothed[1..-2, 1..-2].to_a == written[1..-2, 1..-2].to_a}"
# The default is :mask, because CArray can say "not computed", and a border of
# zeros that means the same cannot be told from zeros that were computed.
puts "  border missing by default  #{smoothed.count_masked} cells"

# ---------------------------------------------------------------- the border

# Five answers, on one row of a small array so they can be read side by side.
line = CArray.double(1, 5).seq!(1.0)              # 1 2 3 4 5

def row (result)
  result.to_a[0].map { |e| e == UNDEF ? "  --" : format("%4.1f", e) }.join(" ")
end

puts
puts "border:, on [1 2 3 4 5] averaging each cell with its two neighbours"
[:mask, :skip, :zero, :clamp, :wrap].each do |border|
  # :skip leaves the border as it was found, so what it was found as is worth
  # seeing: this one is filled with -1 first.
  into = CArray.double(1, 5).seq!(-1.0, 0.0)
  result = CArray.jit_stencil(line, border: border, into: into) { |a|
    (a[0, -1] + a[0, 0] + a[0, 1]) / 3.0
  }
  puts format("  %-6s  %s", border, row(result))
end

# :mask and :skip are answers about the cell -- it is not computed.  The other
# three answer for the read instead, so those cells are computed after all:
# :zero reads 0 outside, :clamp the nearest cell, :wrap the far side.  A Game
# of Life board is a torus because of :wrap; an image filter usually wants
# :clamp.

# --------------------------------------------------- several arrays and rest

# Each array given gets a window, in the order the block names them; the names
# shadow whatever they hold outside, as CArray.fuse's do.  A diffusion step
# with a conductivity that varies from cell to cell:
u = CArray.double(6, 6) { |i, j| (i - 2.5).abs + (j - 2.5).abs }
k = CArray.double(6, 6).fill(0.2)

stepped = CArray.jit_stencil(u, k, border: :clamp) { |u, k|
  u[0,0] + k[0,0] * (u[-1,0] + u[1,0] + u[0,-1] + u[0,1] - 4.0 * u[0,0])
}
puts
puts "several arrays"
puts "  every cell computed        #{stepped.count_masked.zero?}"

# The offsets have to be known before the loop runs -- the radius is what lets
# the interior be walked without asking, at each cell, whether it is inside.
# Arithmetic over literals is not a computed offset: it is folded where the
# block is read, so a stencil drawn from a formula may be written as one.
wide = CArray.jit_stencil(src, border: :clamp) { |a| a[0, -1-1] + a[0, 1+1] }
puts "  a folded offset            #{wide[2, 2] == src[2, 0] + src[2, 4]}"

# What may not appear is anything that has to be read to be known -- a
# captured integer included, since one compiled kernel serves every value of
# it and the loop would not know the radius.
begin
  offset = 1
  CArray.jit_stencil(src) { |a| a[0, offset] }
rescue CArray::JIT::Unsupported => error
  puts "  a computed offset          refused: #{error.message.sub(/ \(at line.*/m, "")}"
end

# ------------------------------------------------------ the array comes back

# Typed from the block's value unless you say otherwise, as jit_map's is.
counts = CArray.jit_stencil(src, border: :zero, type: :int32) { |a|
  a[-1, 0] + a[1, 0] > a[0, 0] ? 1 : 0
}
puts
puts "the result"
puts "  type:                      #{counts.data_type_name}"
# into: writes an array of yours and returns it; the type is then that array's.
mine = CArray.float32(rows, columns)
same = CArray.jit_stencil(src, border: :clamp, into: mine) { |a| a[0, 0] * 2.0 }
puts "  into:                      #{same.equal?(mine)}, and typed #{mine.data_type_name} by it"
