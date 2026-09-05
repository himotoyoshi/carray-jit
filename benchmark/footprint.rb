# What each way of computing an expression holds while it computes it.
#
# A peak is a property of a process, not of a block: an allocation freed
# before the next one is made never shows up beside it.  So each way runs in
# a process of its own and the high-water mark is read from the outside.
#
# What is varied is the number of terms and how they are associated, because
# those are what decide how many buffers are alive at once -- and they decide
# it differently for each way.
#
# For CArray each term is an array while it waits to be combined, so the
# footprint follows the term count.  For fuse walked by CArray it is the shape
# that counts: `ca_binop_func_xfer_stride` pulls its left operand into the
# output buffer it was handed and takes an arena scratch only for its right,
# so a tree leaning left descends for free and a tree leaning right holds one
# buffer per level.  `((t1 + t2) + t3) + t4` and `t1 + (t2 + (t3 + t4))` are
# the same arithmetic and not the same measurement.
#
# Fuse is measured twice, because requiring this gem registers it as CArray's
# expression evaluator: over an array this size the expression is compiled
# rather than walked, and then there is nothing left to hold but the result.
# The walked rows are what CArray does where the gem is not installed.
#
#   ruby benchmark/footprint.rb
#
# Peaks are only comparable within one run of this file: the floor depends on
# what the process loaded and allocated before the expression, so a number
# here means nothing beside a number from a differently-shaped script.

N = 8_000_000
TERMS = [1, 2, 3, 4, 6].freeze

if ARGV.empty?
  require "rbconfig"
  ruby = File.join(RbConfig::CONFIG["bindir"], RbConfig::CONFIG["ruby_install_name"])
  load_path = $LOAD_PATH.grep(/carray-jit/).flat_map { |path| ["-I", path] }

  peak = lambda do |mode, terms, lean|
    report = IO.popen(["/usr/bin/time", "-l", ruby, *load_path, __FILE__,
                       mode, terms.to_s, lean], :err => [:child, :out], &:read)
    line = report.lines.find { |text| text.include?("maximum resident") }
    line && line.split.first.to_i / (1024.0 * 1024.0)
  end

  floor = peak.call("none", 1, "left")
  unless floor
    puts "no peak reported on this platform"
    exit
  end
  puts "peak over the operands, two arrays of #{N} doubles"
  puts "(floor #{'%.0f' % floor} MB; one array is #{'%.0f' % (N * 8 / 1048576.0)} MB)"
  puts
  puts "  terms".ljust(32) + TERMS.map { |t| "%7d" % t }.join
  [["a + b*k, summed",               "plain", "left"],
   ["fuse walked, leaning left",     "walk",  "left"],
   ["fuse walked, leaning right",    "walk",  "right"],
   ["fuse compiled, leaning left",   "fuse",  "left"],
   ["fuse compiled, leaning right",  "fuse",  "right"],
   ["jit_each",                      "jit",   "left"]].each do |label, mode, lean|
    row = TERMS.map { |terms|
      taken = peak.call(mode, terms, lean)
      taken ? "%+7.0f" % (taken - floor) : "      ?"
    }
    puts "  %-30s%s" % [label, row.join]
  end
  exit
end

require "carray/jit"

a = CArray.double(N).seq!
b = CArray.double(N).seq!(0.5, 0.5)
out = CArray.double(N)

mode, count, lean = ARGV[0], ARGV[1].to_i, ARGV[2]
parts = lambda { |x, y| (1..count).map { |k| x + y * k.to_f } }
terms = lambda { |x, y|
  if lean == "right"
    parts.call(x, y).reverse.inject { |sum, term| term + sum }
  else
    parts.call(x, y).inject { |sum, term| sum + term }
  end
}

# Compiling is not what is measured, so the kernel is built first.
CArray.jit_each { out = a } if mode == "jit"

case mode
when "none"  then nil
when "plain" then terms.call(a, b)
when "fuse"  then CArray.fuse { terms.call(a, b) }.to_ca
when "walk"  then
  CArray.expression_evaluator = nil
  CArray.fuse { terms.call(a, b) }.to_ca
when "jit"   then CArray.jit_each { out = terms.call(a, b) }
end
