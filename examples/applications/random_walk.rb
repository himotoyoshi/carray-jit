# Gambler's ruin: how long a random walk lasts, and which end it stops at.
#
# A walk steps up or down by one until it reaches -A or +B.  How many steps
# that takes is different every time and is not bounded by anything, so this
# is `while` again -- but the new part is where the steps come from.  A kernel
# runs with the GVL released, so Ruby's `rand` is not reachable from inside
# one; what is reachable is `CArray::Rng`, whose C the compiler pastes into
# the kernel.  One draw per step, in the loop, at no call.
#
# The answers are known exactly, which is what makes this worth running: a
# walk started at 0 between -A and +B lasts A*B steps on average and stops at
# +B with probability A/(A+B).  A hundred thousand walks should land near
# both.
#
#   ruby examples/applications/random_walk.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

WALKS = 200_000
DOWN, UP = -8, 12                       # the two barriers

def walk (n, seed)
  random = CArray::Rng.new(seed: seed)
  steps = CArray.int32(n)
  ended = CArray.int8(n)                # 1 when it stopped at the top
  CArray.jit_for(n) { |i|
    position = 0
    taken = 0
    while position > DOWN && position < UP
      position = random.random < 0.5 ? position - 1 : position + 1
      taken = taken + 1
    end
    steps[i] = taken
    ended[i] = position == UP ? 1 : 0
  }
  [steps, ended]
end

steps, ended = walk(WALKS, 20260913)

puts format("%d walks between %d and %d", WALKS, DOWN, UP)
puts format("  mean length        %8.2f   (exactly %d)",
            steps.mean, -DOWN * UP)
puts format("  stopped at the top %8.4f   (exactly %.4f)",
            ended.sum.to_f / WALKS, -DOWN.to_f / (UP - DOWN))
puts format("  longest walk       %8d steps", steps.max)

# The shape of it, which no formula on the line above shows.
puts
puts "how long they lasted"
edges = [0, 25, 50, 100, 200, 400, 800, 1 << 30]
edges.each_cons(2) do |low, high|
  count = steps.ge(low).and(steps.lt(high)).count(1)
  width = 60 * count / WALKS
  bar = "#" * (count.positive? ? [width, 1].max : 0)
  label = high > WALKS ? format("%4d+", low) : format("%4d-%-4d", low, high - 1)
  puts format("  %-10s %6d  %s", label, count, bar)
end

# A draw is not fixed to a cell.  Which draw a cell gets is the order the loop
# ran in, so the same seed through the same kernel repeats exactly -- and if a
# cell has to get *its own* draw whatever the loop does, the way to say that
# is to fill an array with `CArray#random!` first and read a cell of it.
again, = walk(WALKS, 20260913)
puts
puts format("the same seed gives the same walks  %s", steps.to_a == again.to_a)

# The same thing in Ruby, which is where a Monte Carlo usually starts life.
def walk_in_ruby (n, seed)
  random = Random.new(seed)
  steps = Array.new(n, 0)
  n.times do |i|
    position = 0
    taken = 0
    while position > DOWN && position < UP
      position = random.rand < 0.5 ? position - 1 : position + 1
      taken += 1
    end
    steps[i] = taken
  end
  steps
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
3.times { walk(WALKS, 20260913) }
compiled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 3

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
in_ruby = walk_in_ruby(WALKS, 20260913)
interpreted = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts
puts format("%d walks, about %d draws in all", WALKS, steps.sum)
puts format("  %6.1f ms compiled, %6.0f ms in Ruby (%.0fx)",
            compiled * 1e3, interpreted * 1e3, interpreted / compiled)
puts format("  Ruby's own walks average %.2f steps, which is the same law",
            in_ruby.sum.to_f / WALKS)
