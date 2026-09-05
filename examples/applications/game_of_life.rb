# Conway's Game of Life
#
# A generation is a stencil: nine reads and two comparisons per cell.  Written
# with CArray's operators it would be eight shifted arrays added together, and
# eight passes over the board to do it; written as a Ruby loop it would be a
# block call per cell.  Written here it is the rule as it is stated, run once
# per cell.
#
# It is written twice.  With the indices named the extents say which cells are
# written, and the border is what they leave out -- the board has edges, and a
# glider that reaches one dies there.  With windows the border is an argument
# instead, and `border: :wrap` is what makes the board the torus the rules are
# usually stated on.
#
#   ruby examples/applications/game_of_life.rb

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "carray/jit"

ROWS, COLUMNS = 24, 48

def step (current, following)
  rows, columns = current.dim
  CArray.jit_for(1...(rows-1), 1...(columns-1)) { |i, j|
    neighbours = current[i-1, j-1] + current[i-1, j] + current[i-1, j+1] +
                 current[i,   j-1] +                   current[i,   j+1] +
                 current[i+1, j-1] + current[i+1, j] + current[i+1, j+1]
    if neighbours == 3
      following[i, j] = 1
    elsif neighbours == 2
      following[i, j] = current[i, j]
    else
      following[i, j] = 0
    end
  }
end

# The same rule with windows onto the board instead of indices.  `a[0, 0]` is
# the cell, `a[-1, -1]` its neighbour, and the block's value is what the cell
# gets -- so the rule is an expression, and there is no loop and no extent to
# write.  `border: :wrap` says that a read off one edge comes back the other
# side, which is the whole of what makes this a torus.
def step_torus (current, following)
  CArray.jit_stencil(current, border: :wrap, into: following) { |a|
    neighbours = a[-1, -1] + a[-1, 0] + a[-1, 1] +
                 a[0,  -1] +            a[0,  1] +
                 a[1,  -1] + a[1,  0] + a[1,  1]
    neighbours == 3 ? 1 : (neighbours == 2 ? a[0, 0] : 0)
  }
end

def draw (board, title)
  puts title
  board.to_a.each { |row| puts "  " + row.map { |cell| cell == 1 ? "#" : "·" }.join }
end

board = CArray.int32(ROWS, COLUMNS)
scratch = CArray.int32(ROWS, COLUMNS)

# A glider, and an r-pentomino to make a mess of things.
[[2,2],[3,3],[4,1],[4,2],[4,3]].each { |i, j| board[i, j] = 1 }
[[12,20],[12,21],[13,19],[13,20],[14,20]].each { |i, j| board[i, j] = 1 }

draw(board, "generation 0")

64.times do |generation|
  step(board, scratch)
  board, scratch = scratch, board
  draw(board, "generation #{generation + 1}") if generation + 1 == 16 ||
                                                 generation + 1 == 32
end

# The glider has walked down and to the right; the r-pentomino has burned
# itself out against the edge.  The board is a torus in the usual statement of
# the rules -- here the border is simply not written, which is what the extents
# say, and nothing else in the program had to know it.

# Away from the edges the two spellings are the same rule, and agree on it.
sample = CArray.int32(ROWS, COLUMNS)
[[5,5],[5,6],[5,7],[6,4],[6,5],[6,6],[9,20],[10,21],[11,19],[11,20],[11,21]].each { |i, j|
  sample[i, j] = 1
}
by_index = CArray.int32(ROWS, COLUMNS)
by_window = CArray.int32(ROWS, COLUMNS)
step(sample, by_index)
step_torus(sample, by_window)
interior = [1...(ROWS-1), 1...(COLUMNS-1)]
puts
puts "the two spellings, on the interior: " \
     "#{by_index[*interior].to_a == by_window[*interior].to_a}"

# On the torus the glider does not run out of board.  A small one, so that it
# reaches the corner while there is still something to watch.
SIDE = 16
torus = CArray.int32(SIDE, SIDE)
spare = CArray.int32(SIDE, SIDE)
[[1,2],[2,3],[3,1],[3,2],[3,3]].each { |i, j| torus[i, j] = 1 }
started_from = torus.copy               # `to_ca` would answer this same array

draw(torus, "torus, generation 0")
64.times do |generation|
  step_torus(torus, spare)
  torus, spare = spare, torus
  draw(torus, "torus, generation #{generation + 1}") if generation + 1 == 52 ||
                                                        generation + 1 == 64
end

# It left by the bottom right and came back at the top left, unchanged: a
# glider on a torus of side 16 is back where it started after 64 generations,
# which is the check on `:wrap` -- the board has no edge for it to die on.
puts "  the glider came home:            #{torus.to_a == started_from.to_a}"

# How long a generation takes, against the same rule as a Ruby loop.
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
100.times { step(board, scratch); board, scratch = scratch, board }
compiled = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 100

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
5.times do
  (1...(ROWS-1)).each do |i|
    (1...(COLUMNS-1)).each do |j|
      neighbours = board[i-1, j-1] + board[i-1, j] + board[i-1, j+1] +
                   board[i,   j-1] +                 board[i,   j+1] +
                   board[i+1, j-1] + board[i+1, j] + board[i+1, j+1]
      scratch[i, j] = neighbours == 3 ? 1 : (neighbours == 2 ? board[i, j] : 0)
    end
  end
end
interpreted = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 5

step_torus(board, scratch)              # compiled once, then measured
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
100.times { step_torus(board, scratch); board, scratch = scratch, board }
wrapped = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 100

puts format("a generation: %.3f ms with the indices named, %.3f ms as a window " \
            "on a torus, %.3f ms in Ruby (%.0fx)",
            compiled * 1e3, wrapped * 1e3, interpreted * 1e3, interpreted / compiled)

# The window is not the slower rule; this board is small.  Its frame is a
# tenth of its cells, and the frame is where the wrap is woven into the reads
# -- and a generation here is measured in tens of microseconds, so the cost of
# making the call at all is in the number too.  On a board where neither is
# true the two are level:
LARGE = 1200
crowd = CArray.int32(LARGE, LARGE).random!(2)
next_crowd = CArray.int32(LARGE, LARGE)
step(crowd, next_crowd)
step_torus(crowd, next_crowd)

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
10.times { step(crowd, next_crowd) }
large_indexed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 10

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
10.times { step_torus(crowd, next_crowd) }
large_wrapped = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 10

puts format("a generation on %d x %d: %.2f ms with the indices named, " \
            "%.2f ms as a window on a torus",
            LARGE, LARGE, large_indexed * 1e3, large_wrapped * 1e3)
