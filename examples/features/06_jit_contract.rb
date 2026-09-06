# Contractions: an index that appears twice is summed.
#
# An index that appears twice in the term is summed -- the repetition is what
# stands in for the sigma.  No extents are given, because each index's extent
# is fixed by the axes it addresses, and an index whose axes disagree is
# refused: that shape check is what a contraction is for.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

a = CArray.double(3, 4).seq!(1.0)
b = CArray.double(4, 2).seq!(0.5, 0.5)
v = CArray.double(4).seq!(1.0)
p = CArray.double(3).seq!(1.0)
r = CArray.double(2).seq!(10.0, 10.0)
q = CArray.double(3, 3).seq!(1.0)

matmul = CArray.jit_contract { |i, j, k| a[i,k] * b[k,j] }  # k is summed
matvec = CArray.jit_contract { |i, k|    a[i,k] * v[k]    }  # k is summed
dot    = CArray.jit_contract { |i, k|    a[i,k] * a[i,k]  }  # both, one cell
trace  = CArray.jit_contract { |i|       q[i,i]           }  # one array, twice
outer  = CArray.jit_contract { |i, j|    p[i] * r[j]      }  # nothing summed

puts "contractions"
puts "  a . b     #{matmul.to_a.inspect}"
puts "  a . v     #{matvec.to_a.inspect}"
puts "  |a|^2     #{dot[0]}   (#{a.to_a.flatten.sum { |e| e * e }})"
puts "  tr q      #{trace[0]}"
puts "  p (x) r   #{outer.to_a.inspect}"

# The result's axes are the free indices in the order the block named them, so
# the parameter list is where the axis order is stated -- and swapping two
# parameters transposes.
transposed = CArray.jit_contract { |j, i, k| a[i,k] * b[k,j] }
puts "  swapped   #{transposed.dim.inspect} vs #{matmul.dim.inspect}"

# Assigning into an array of your own says where to put it instead.  It must
# name exactly the free indices, and still does not decide what is summed.
destination = CArray.double(3, 2)
CArray.jit_contract { |i, j, k| destination[i,j] = a[i,k] * b[k,j] }
puts "  into mine #{destination.to_a == matmul.to_a}"

# A sum along an axis is not a contraction: there is nothing in a[i,k]
# standing in for a sigma.
begin
  total = CArray.double(3)
  CArray.jit_contract { |i, k| total[i] = a[i,k] }
rescue CArray::JIT::Unsupported => error
  puts "  refused:  #{error.message.lines.first.strip}"
end

# Nor is a shape mismatch let through.
begin
  wrong = CArray.double(5, 2)
  CArray.jit_contract { |i, j, k| a[i,k] * wrong[k,j] }
rescue CArray::JIT::Unsupported => error
  puts "  refused:  #{error.message.lines.first.strip}"
end
