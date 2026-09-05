# Seeing what was compiled, and what is refused.
#
# The generated C is the debugging surface: `jit_for` returns the kernel, and
# the kernel carries its source.  Running with CARRAY_JIT_DUMP=1 prints the
# same thing for every kernel as it is compiled, and `carray-jit list` / `show`
# report what is cached on disk between runs.

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

values = CArray.double(16).seq!(1.0)

def sweep (values)
  CArray.jit_for(1...values.dim[0]) { |i| values[i] = Math.sqrt(values[i-1]) + 1.0 }
end

kernel = sweep(values)

# The contiguous loop, as it was handed to the compiler.
puts "generated C"
puts kernel.c_source[/^static void\ncarray_jit_contiguous.*?^\}$/m].lines.map { |line| "  " + line.rstrip }

# Every kernel carries two loops and decides between them once, outside the
# loop: the contiguous form indexes a typed pointer and can be vectorised, the
# strided form is what lets a view run without being copied first.
puts "  both loops present  #{%w[carray_jit_contiguous carray_jit_strided].all? { |name| kernel.c_source.include?(name) }}"

# Compiling happens once.  The second call finds the object already loaded, the
# second run of the script finds it on disk.
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sweep(values)
again = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
puts "  second call         #{format('%.4f ms', again * 1e3)} (the same block, already loaded)"

# Anything outside the subset raises rather than falling back, and says where.
# A silent fallback would turn a typo into a performance mystery.
puts
puts "refused"
[
  proc { CArray.jit_for(16) { |i| values[i] = values.to_a.max } },
  proc { CArray.jit_for(16) { |i| values[i] = "text" } },
  proc { n = 0; CArray.jit_for(16) { |i| while n < 3 do n += 1 end } },
].each do |attempt|
  begin
    attempt.call
  rescue CArray::JIT::Unsupported => error
    puts "  #{error.message.lines.first.strip}"
  end
end

puts
puts "the cache lives under #{CArray::JIT::Compiler.cache_directory}"
puts "  carray-jit list          what is cached for this environment"
puts "  carray-jit show <prefix> the C source of one cached kernel"
puts "  carray-jit clear         remove it"
