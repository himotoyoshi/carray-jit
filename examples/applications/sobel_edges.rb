# Edge detection on an image
#
# A Sobel filter is two 3x3 convolutions and a hypotenuse.  With array
# operators that is eighteen shifted arrays, eighteen passes over the image and
# a dozen temporaries the size of it; here it is the filter as written, one
# pass, nothing allocated in between.
#
#   ruby examples/applications/sobel_edges.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

def sobel (image, edges)
  rows, columns = image.dim
  CArray.jit_for(1...(rows-1), 1...(columns-1)) { |i, j|
    gx = (image[i-1, j+1] + 2.0 * image[i, j+1] + image[i+1, j+1]) -
         (image[i-1, j-1] + 2.0 * image[i, j-1] + image[i+1, j-1])
    gy = (image[i+1, j-1] + 2.0 * image[i+1, j] + image[i+1, j+1]) -
         (image[i-1, j-1] + 2.0 * image[i-1, j] + image[i-1, j+1])
    edges[i, j] = Math.sqrt(gx * gx + gy * gy)
  }
end

# A synthetic picture: a disc, a bar, and a soft background gradient.
rows, columns = 40, 96
image = CArray.double(rows, columns)
rows.times do |i|
  columns.times do |j|
    y = (i - 20.0) / 16.0
    x = (j - 30.0) / 16.0
    value = 0.25 * (j.to_f / columns)
    value += 0.7 if x * x + y * y < 1.0                          # the disc
    value += 0.6 if i.between?(8, 30) && j.between?(58, 84)      # the bar
    image[i, j] = value
  end
end

edges = CArray.double(rows, columns)
sobel(image, edges)

def draw (field, title)
  puts title
  scale = field.max
  field.to_a.each_slice(2) do |row, _|
    puts "  " + row.each_slice(1).map { |v|
      " .:-=+*#@"[[(v.first / scale * 8).round, 8].min]
    }.join
  end
end

draw(image, "image")
draw(edges, "edges")

# On an image of a size you would actually filter -- the same filter, and the
# same loop written in Ruby, both over the whole thing.
size = 512
large = CArray.double(size, size) { |i, j| Math.sin(i * 0.03) * Math.cos(j * 0.02) }
result = CArray.double(size, size)

sobel(large, result)   # compile it before timing it
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
5.times { sobel(large, result) }
compiled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 5

reference = CArray.double(size, size)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
(1...(size-1)).each do |i|
  (1...(size-1)).each do |j|
    gx = (large[i-1, j+1] + 2.0 * large[i, j+1] + large[i+1, j+1]) -
         (large[i-1, j-1] + 2.0 * large[i, j-1] + large[i+1, j-1])
    gy = (large[i+1, j-1] + 2.0 * large[i+1, j] + large[i+1, j+1]) -
         (large[i-1, j-1] + 2.0 * large[i-1, j] + large[i-1, j+1])
    reference[i, j] = Math.sqrt(gx * gx + gy * gy)
  end
end
interpreted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts format("%dx%d image: %.1f ms compiled, %.0f ms as a Ruby loop (%.0fx)",
            size, size, compiled * 1e3, interpreted * 1e3, interpreted / compiled)
puts "  identical results: #{result.to_a == reference.to_a}"
