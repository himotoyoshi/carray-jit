# From how many cells on a compiled kernel is worth calling.
#
# element_wise.rb answers "how much faster", at four million cells, where the
# call's fixed cost has long since vanished into the arithmetic.
# call_overhead.rb answers "what does one call cost", at one cell, where
# nothing but the fixed cost is left.  An application stands somewhere between
# the two and has to know which side of the crossing it is on, and neither
# benchmark says.
#
# Where the crossing falls is not a property of this gem alone.  What a kernel
# saves per cell is set by how many passes over the data the plain spelling
# would have made, and by how much the plain spelling has to copy before it
# can line the cells up at all.  What the kernel costs per call is set by how
# many arrays it touches -- 12.5 us plus 3.3 us an operand, which is what
# call_overhead.rb measures.  So the crossing moves by expression, and the
# only useful answer is one per expression shape.
#
# The plain spelling here is the one a caller would actually have written, not
# a handicapped one, and the two are checked against each other: a crossing
# measured against a spelling that computes something else is not a crossing.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "carray/jit"

SIZES = [500, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000].freeze
SAMPLES = 9

# The best of the batches rather than the middle one.  The plain spelling
# allocates an intermediate array per operation, so what varies between
# batches is how much of the allocator and the collector each one caught --
# noise on top of the cost, never under it.  Taking the middle of it made the
# two curves cross, uncross and cross again, which is an artefact and not a
# crossing.
def per_call (size)
  repeats = [[4_000_000 / size, 40].max, 4_000].min
  2.times { repeats.times { yield } }
  GC.start
  SAMPLES.times.map {
    Benchmark.realtime { repeats.times { yield } } / repeats
  }.min
end

# Where the two curves cross, read off the pair of sizes that straddle it.
# Interpolated on log(size), since the sizes are a geometric ladder and both
# curves are closer to straight in log than in size.
#
# The crossing has to hold: the first size the kernel leads at counts only if
# it leads at every larger size too.  A single size where it happens to come
# out ahead is the measurement moving, and reporting it as the crossing would
# tell a caller their model is on the far side when it is not.
def crossing_between (points)
  ratios = points.map { |size, jit, plain| [size, plain / jit] }
  index = ratios.each_index.find { |i|
    ratios[i..].all? { |_, ratio| ratio >= 1.0 }
  }
  return :beyond unless index
  return :always if index.zero?
  low_size, low_ratio = ratios[index - 1]
  size, ratio = ratios[index]
  span = Math.log(size.to_f / low_size)
  (low_size * Math.exp(span * (1.0 - low_ratio) / (ratio - low_ratio))).round
end

def largest_difference (first, second)
  (first - second).abs.max
end

# One case is a name, the arrays it needs, the kernel, and the plain spelling
# of the very same computation.
Case = Struct.new(:name, :note, :build)

CASES = [
  Case.new("out = a + b", "two arrays, and one pass either way: " \
                          "the least a kernel can save",
    ->(n) {
      a = CArray.double(n).seq; b = CArray.double(n).seq
      out = CArray.double(n); plain_out = CArray.double(n)
      [proc { CArray.jit_each { out = a + b } },
       proc { plain_out[] = a + b },
       proc { largest_difference(out, plain_out) }]
    }),

  Case.new("out = a + b + c + d", "four arrays, and three passes and three " \
                                  "intermediate arrays saved",
    ->(n) {
      a = CArray.double(n).seq; b = CArray.double(n).seq
      c = CArray.double(n).seq; d = CArray.double(n).seq
      out = CArray.double(n); plain_out = CArray.double(n)
      [proc { CArray.jit_each { out = a + b + c + d } },
       proc { plain_out[] = a + b + c + d },
       proc { largest_difference(out, plain_out) }]
    }),

  Case.new("out = (a + b) * (c - a) + b * c - a", "the long expression from " \
                                                  "element_wise.rb",
    ->(n) {
      a = CArray.double(n).seq; b = CArray.double(n).seq
      c = CArray.double(n).seq
      out = CArray.double(n); plain_out = CArray.double(n)
      [proc { CArray.jit_each { out = (a + b) * (c - a) + b * c - a } },
       proc { plain_out[] = (a + b) * (c - a) + b * c - a },
       proc { largest_difference(out, plain_out) }]
    }),

  Case.new("three-point stencil", "the plain spelling has to make the three " \
                                  "shifted views first",
    ->(n) {
      a = CArray.double(n).seq
      out = CArray.double(n); plain_out = CArray.double(n)
      [proc { CArray.jit_for(1...(n - 1)) { |i| out[i] = a[i-1] + a[i] + a[i+1] } },
       proc { plain_out[1..-2] = a[0..-3] + a[1..-2] + a[2..-1] },
       proc { largest_difference(out[1..-2], plain_out[1..-2]) }]
    }),

  Case.new("periodic tendency, eight fields", "the shape a one-dimensional " \
                                              "shallow-water model has",
    ->(n) {
      eta = CArray.double(n).seq; u = CArray.double(n).seq
      v = CArray.double(n).seq
      fc = CArray.double(n).seq; ff = CArray.double(n).seq
      d_eta = CArray.double(n); d_u = CArray.double(n); d_v = CArray.double(n)
      plain_eta = CArray.double(n); plain_u = CArray.double(n)
      plain_v = CArray.double(n)
      g = 9.8; h = 100.0; dx = 50.0
      [proc {
         CArray.jit_for(n) { |i|
           ip = (i + 1) % n
           im = (i + n - 1) % n
           d_eta[i] = -((h * u[ip] - h * u[i]) / dx)
           d_u[i]   = ff[i] * ((v[i] + v[im]) / 2) - (g * eta[i] - g * eta[im]) / dx
           d_v[i]   = -(fc[i] * ((u[i] + u[ip]) / 2))
         }
       },
       proc {
         plain_eta[] = -((h * u.roll(-1) - h * u) / dx)
         plain_u[]   = ff * ((v + v.roll(1)) / 2) - (g * eta - g * eta.roll(1)) / dx
         plain_v[]   = -(fc * ((u + u.roll(-1)) / 2))
       },
       proc {
         [largest_difference(d_eta, plain_eta),
          largest_difference(d_u, plain_u),
          largest_difference(d_v, plain_v)].max
       }]
     }),
].freeze

CASES.each do |example|
  puts example.name
  puts "  (#{example.note})"
  puts format("  %8s  %10s  %10s  %8s", "n", "jit", "plain", "")

  differences = []
  points = SIZES.map { |size|
    kernel, plain, compare = example.build.call(size)
    kernel.call
    plain.call
    differences << compare.call
    [size, per_call(size, &kernel), per_call(size, &plain)]
  }

  points.each do |size, jit, plain|
    ratio = plain / jit
    puts format("  %8d  %8.2f us  %8.2f us  %6.2fx%s",
                size, jit * 1e6, plain * 1e6, ratio,
                ratio >= 1.0 ? "  kernel ahead" : "")
  end

  case (crossing = crossing_between(points))
  when :always
    puts "  the kernel is ahead at every size measured"
  when :beyond
    puts format("  the kernel is still behind at n = %d", SIZES.last)
  else
    puts format("  crossing at n = %d", crossing)
  end

  # The same computation, or the crossing means nothing.
  puts format("  largest difference from the plain spelling: %s",
              differences.max)
  puts
end

puts "for what one call costs before any cell is touched, run " \
     "benchmark/call_overhead.rb"
