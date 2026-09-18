# Floyd-Steinberg dithering: one bit per pixel, and the error passed on.
#
# Each pixel is rounded to black or white, and what the rounding threw away is
# handed to the neighbours that have not been visited yet -- seven sixteenths
# to the right, and the rest to the row below.  So a cell writes the cells the
# loop is about to read, and the order it visits them in is not an
# optimisation but the definition: run the same rule right to left and a
# different picture comes out.
#
# That is what separates this from `sobel_edges.rb`, where every cell only
# reads its neighbours and the pass is a stencil.  Here there is no window, no
# expression over whole arrays, and no order to be derived -- there is a walk,
# and the walk is the algorithm.  The kernel is one cell whose body is that
# walk, which is the shape to reach for when the order is the point.
#
#   ruby examples/applications/dithering.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

# A grey ramp, top to bottom, with a brighter disc sitting in it.
def picture (rows, columns)
  image = CArray.double(rows, columns)
  CArray.jit_for(rows, columns) { |y, x|
    dy = (y - rows / 2.0) / (rows / 2.0)
    dx = (x - columns / 2.0) / (columns / 2.0) * 0.42
    ramp = 0.08 + 0.84 * y / rows
    image[y, x] = dx * dx + dy * dy < 0.16 ? ramp * 0.35 + 0.62 : ramp
  }
  image
end

# The work array carries a row below and a column on each side, so that the
# four neighbours a pixel writes are always cells that exist.  A kernel's
# bounds are checked against the subscripts it is written with rather than
# against the branches that guard them, so the room is made in the array, not
# in an `if`.
def dither (image)
  rows, columns = image.dim
  out = CArray.int8(rows, columns)
  work = CArray.double(rows + 1, columns + 2)
  work[0..-2, 1..-2] = image
  CArray.jit_for(1) { |z|
    (0...rows).each { |y|
      (0...columns).each { |x|
        old = work[y, x + 1]
        new = old > 0.5 ? 1.0 : 0.0
        out[y, x] = new
        error = old - new
        work[y, x + 2] += error * 7.0 / 16.0
        work[y + 1, x] += error * 3.0 / 16.0
        work[y + 1, x + 1] += error * 5.0 / 16.0
        work[y + 1, x + 2] += error * 1.0 / 16.0
      }
    }
  }
  out
end

ROWS, COLUMNS = 22, 72

def show (bits, title)
  puts title
  bits.dim[0].times do |y|
    puts "  " + (0...bits.dim[1]).map { |x| bits[y, x] == 1 ? "@" : " " }.join
  end
  puts
end

image = picture(ROWS, COLUMNS)

# Rounding each pixel on its own is an expression over the whole array, and it
# is what the error has to be passed on to avoid: a ramp becomes two flat
# bands with a step where it crosses a half.
show(image.gt(0.5).int8, "rounded, each pixel on its own")
show(dither(image), "dithered, the error passed on")

# The same walk in Ruby, at a size worth timing.
def dither_in_ruby (image)
  rows, columns = image.dim
  out = Array.new(rows) { Array.new(columns, 0) }
  work = Array.new(rows + 1) { Array.new(columns + 2, 0.0) }
  rows.times { |y| columns.times { |x| work[y][x + 1] = image[y, x] } }
  rows.times do |y|
    columns.times do |x|
      old = work[y][x + 1]
      new = old > 0.5 ? 1.0 : 0.0
      out[y][x] = new.to_i
      error = old - new
      work[y][x + 2] += error * 7.0 / 16.0
      work[y + 1][x] += error * 3.0 / 16.0
      work[y + 1][x + 1] += error * 5.0 / 16.0
      work[y + 1][x + 2] += error * 1.0 / 16.0
    end
  end
  out
end

large = picture(600, 600)
here = dither(large)
there = dither_in_ruby(large)
puts format("600x600, agrees with Ruby  %s", here.to_a == there)

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
5.times { dither(large) }
compiled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 5

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
dither_in_ruby(large)
interpreted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts format("  %.1f ms compiled, %.0f ms in Ruby (%.0fx)",
            compiled * 1e3, interpreted * 1e3, interpreted / compiled)

# Right to left, with the offsets mirrored: the same rule, the same picture
# going in, and a different picture coming out.  Nothing here is wrong with
# either -- the walk is part of what the algorithm says, which is why this is
# not a pass an expression over arrays could have been rearranged into.
def dither_backwards (image)
  rows, columns = image.dim
  out = CArray.int8(rows, columns)
  work = CArray.double(rows + 1, columns + 2)
  work[0..-2, 1..-2] = image
  CArray.jit_for(1) { |z|
    (0...rows).each { |y|
      (columns - 1).step(0, -1) { |x|
        old = work[y, x + 1]
        new = old > 0.5 ? 1.0 : 0.0
        out[y, x] = new
        error = old - new
        work[y, x] += error * 7.0 / 16.0
        work[y + 1, x + 2] += error * 3.0 / 16.0
        work[y + 1, x + 1] += error * 5.0 / 16.0
        work[y + 1, x] += error * 1.0 / 16.0
      }
    }
  }
  out
end

differ = dither(large).ne(dither_backwards(large)).count(1)
puts
puts format("walked the other way, %d of %d pixels land differently (%.1f%%)",
            differ, large.elements, 100.0 * differ / large.elements)
