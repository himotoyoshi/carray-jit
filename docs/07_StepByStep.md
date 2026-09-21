# 30 carray-jit exercises, with solutions

Thirty small tasks, in the order the documentation introduces things, with a
solution under each. Roughly in order of difficulty -- the stars say how much
of the subset a task leans on, not how much code it takes.

They run as written. Start with

```ruby
require "carray"
require "carray/jit"
```

and every `#=>` is what that line actually answers.

Read the task, try it, then look. Where the answer is that the compiler
refuses something, the refusal is the answer and is printed under the code.

---

#### 1. Compute `a + b * c` into `out` in a single pass, with no array built in between (★☆☆)

`hint: the method for work that reaches no neighbour`

```ruby
a = CA_DOUBLE([1, 2, 3])
b = CA_DOUBLE([2, 3, 4])
c = CA_DOUBLE([3, 4, 5])
out = CArray.double(3)

CArray.jit_each { out = a + b * c }
out.to_a                            #=> [7.0, 14.0, 23.0]
```

#### 2. Compute `(a + b * c) / 2` over three int32 arrays, taking the result back as a new array. What is its data type? (★☆☆)

`hint: the other element-wise method`

```ruby
a = CA_INT32([1, 2, 3])
b = CA_INT32([2, 3, 4])
c = CA_INT32([3, 4, 5])

half = CArray.jit_map { (a + b * c) / 2.0 }
half.to_a                           #=> [3.5, 7.0, 11.5]
half.data_type_name                 #=> "float64"
# typed from the block's last value, not from the arrays: `2.0` has no width
# of its own, so it takes the one it meets.  Without it, int64.
```

#### 3. Add a row of three to every row of a 2x3 table into `out`, without copying the row (★☆☆)

`hint: CArray will broadcast an axis, but not invent a rank`

```ruby
table = CArray.double(2, 3).seq!(1.0)
row = CA_DOUBLE([10, 20, 30]).reshape(1, 3)   # 1x3, not 3: else `ndim mismatch`
out = CArray.double(2, 3)

CArray.jit_each { out = table + row }
out.to_a                            #=> [[11.0, 22.0, 33.0], [14.0, 25.0, 36.0]]
```

#### 4. Scale an array by a Float the block closes over, twice with different values and compiling only once. Collect both results (★☆☆)

`hint: nothing special is needed`

```ruby
a = CA_DOUBLE([1, 2])
out = CArray.double(2)

[2.0, 5.0].map { |gain|
  CArray.jit_each { out = a * gain }   # a captured scalar is an argument,
  out.to_a                             # not a constant compiled in
}                                   #=> [[2.0, 4.0], [5.0, 10.0]]
```

#### 5. Scale an array into `out` by a factor that carries a data type of its own (★☆☆)

`hint: CScalar`

```ruby
a = CA_DOUBLE([1, 2])
gain = CScalar.double() { 2.5 }
out = CArray.double(2)

CArray.jit_each { out = a * gain }
out.to_a                            #=> [2.5, 5.0]
```

#### 6. Write each value into `out`, with the negatives clipped to zero (★☆☆)

`hint: the branch is an expression`

```ruby
a = CA_DOUBLE([-2, 0, 1.5, 3])
out = CArray.double(4)

CArray.jit_each { out = a < 0.0 ? 0.0 : a }
out.to_a                            #=> [0.0, 0.0, 1.5, 3.0]
```

#### 7. Write a vector into `out` reversed (★☆☆)

`hint: the cell has to say which cell it reads`

```ruby
a = CArray.double(5).seq!(1.0)
out = CArray.double(5)

CArray.jit_for(5) { |i| out[i] = a[4 - i] }
out.to_a                            #=> [5.0, 4.0, 3.0, 2.0, 1.0]
```

#### 8. First differences: `out[i] = a[i] - a[i-1]`, leaving `out[0]` at zero (★☆☆)

`hint: where can the range start?`

```ruby
a = CA_DOUBLE([1, 3, 6, 10])
out = CArray.double(4)

CArray.jit_for(1...4) { |i| out[i] = a[i] - a[i - 1] }
out.to_a                            #=> [0.0, 2.0, 3.0, 4.0]
# 1... and not 0...: bounds are checked against the subscript as written,
# before the loop runs, so a guard inside the body would not help.
```

#### 9. `out[i] = 0.5 * a[i] + 0.5 * out[i-1]`, with `out[0] = a[0]` (★★☆)

`hint: read what this loop just wrote`

```ruby
a = CA_DOUBLE([4, 8, 8, 8])
out = CArray.double(4)
out[0] = a[0]

CArray.jit_for(1...4) { |i| out[i] = 0.5 * a[i] + 0.5 * out[i - 1] }
out.to_a                            #=> [4.0, 6.0, 7.0, 7.5]
```

#### 10. Write a 2x3 into `out` transposed, as a 3x2 (★☆☆)

`hint: two parameters, two extents`

```ruby
a = CArray.double(2, 3).seq!(1.0)
out = CArray.double(3, 2)

CArray.jit_for(2, 3) { |i, j| out[j, i] = a[i, j] }
out.to_a                            #=> [[1.0, 4.0], [2.0, 5.0], [3.0, 6.0]]
```

#### 11. Write the largest value of each row into `out` (★☆☆)

`hint: a loop inside the cell`

```ruby
a = CA_DOUBLE([[1, 3, 2], [9, 4, 5]])
out = CArray.double(2)

CArray.jit_for(2) { |i|
  best = a[i, 0]
  (1...3).each { |j| best = a[i, j] if a[i, j] > best }
  out[i] = best
}
out.to_a                            #=> [3.0, 9.0]
```

#### 12. Total an int32 array into a single value the kernel writes (★☆☆)

`hint: a local does not survive the iteration`

```ruby
a = CArray.int32(10).seq!(1)
total = CScalar.int32() { 0 }

CArray.jit_for(10) { |i| total[] += a[i] }
total[0]                            #=> 55
```

#### 13. Given the bin number of each reading, count the readings of every bin into `counts` (★★☆)

`hint: the subscript is a value, not the index`

```ruby
bin = CA_INT32([0, 2, 1, 1, 0, 1])
counts = CArray.int32(3)

CArray.jit_for(6) { |i| counts[bin[i]] += 1 }
counts.to_a                         #=> [2, 3, 1]
```

#### 14. Write the distance from the origin of each (x, y) into `out` (★☆☆)

`hint: Math`

```ruby
x = CA_DOUBLE([3, 5])
y = CA_DOUBLE([4, 12])
out = CArray.double(2)

CArray.jit_each { out = Math.sqrt(x * x + y * y) }
out.to_a                            #=> [5.0, 13.0]
```

#### 15. Give `jit_each` a block that names an index, and `jit_for` one that names none. What comes back? (★★☆)

`hint: neither guesses`

```ruby
a = CA_DOUBLE([1, 2, 3])
out = CArray.double(3)

CArray.jit_each { |i| out[i] = a[i] + 1.0 }
#=> CArray::JIT::Unsupported: this block names the arrays it reaches, so it
#   takes no parameters; for a loop that names its indices, see `jit_for`

CArray.jit_for(3) { out = a + 1.0 }
#=> CArray::JIT::Unsupported: jit_for's block names the cells it is on, so it
#   takes the loop indices as its parameters; a block that names none is
#   element-wise and belongs to jit_each
```

#### 16. Write how many decimal digits each number has into `digits` (★★☆)

`hint: divide by ten until there is nothing left -- but how many times is that?`

```ruby
value = CA_INT32([7, 42, 1000, 65536])
digits = CArray.int32(4)

CArray.jit_for(4) { |i|
  n = value[i]
  count = 0
  while n > 0                       # one cell goes round once, another five
    n = n / 10                      # integer division, and Ruby's: it floors
    count = count + 1
  end
  digits[i] = count
}
digits.to_a                         #=> [1, 2, 4, 5]
```

#### 17. Write the first column past 4.0 in each row into `first`, or -1 where there is none (★★☆)

`hint: stop looking`

```ruby
rows = CA_DOUBLE([[1, 2, 9, 3], [5, 1, 1, 8]])
first = CArray.int32(2)

CArray.jit_for(2) { |i|
  found = -1
  (0...4).each { |j|
    if rows[i, j] > 4.0
      found = j
      break
    end
  }
  first[i] = found
}
first.to_a                          #=> [2, 0]
```

#### 18. Multiply a 2x3 by a 3x2, taking the result back (★★☆)

`hint: the index that repeats`

```ruby
a = CArray.double(2, 3).seq!(1.0)
b = CArray.double(3, 2).seq!(1.0)

CArray.jit_contract { |i, j, k| a[i, k] * b[k, j] }.to_a
#=> [[22.0, 28.0], [49.0, 64.0]]
```

#### 19. For each row `i` of two 2x3 arrays, take back the sum over `k` of `x[i, k] * y[i, k]` (★★★)

`hint: the row index repeats too, and must not be summed`

```ruby
x = CA_DOUBLE([[1, 2, 3], [4, 5, 6]])
y = CA_DOUBLE([[1, 1, 1], [2, 2, 2]])

CArray.jit_contract(:b) { |k| x[b, k] * y[b, k] }.to_a
#=> [6.0, 30.0]
# `b` is named in the call, not taken as a parameter; both at once is refused
```

#### 20. Take back each cell plus its two neighbours, with a cell off the end reading as zero (★★☆)

`hint: no index, no extent, no edge`

```ruby
a = CA_DOUBLE([1, 2, 3, 4])

CArray.jit_stencil(a, border: :zero) { |w| w[-1] + w[0] + w[1] }.to_a
#=> [3.0, 6.0, 9.0, 7.0]
# border: :zero, :clamp, :wrap compute the frame; :mask and :skip answer
# about the frame cells themselves
```

#### 21. Write every cell into `out`, with `UNDEF` replaced by zero (★★☆)

`hint: ask about one cell`

```ruby
a = CA_DOUBLE([1, 2, 3])
a[1] = UNDEF
out = CArray.double(3)

CArray.jit_for(3) { |i| out[i] = a[i] == UNDEF ? 0.0 : a[i] }
out.to_a                            #=> [1.0, 0.0, 3.0]
# where "propagate" is the answer wanted, write nothing: masks are ORed
# across the inputs and carried to the outputs on their own
```

#### 22. Write 1, 2, 3 down the middle column of a 3x3, leaving the rest (★★☆)

`hint: hand the kernel the column`

```ruby
table = CArray.double(3, 3)
column = table[nil, 1]

CArray.jit_for(3) { |i| column[i] = i + 1.0 }
table.to_a                          #=> [[0.0, 1.0, 0.0], [0.0, 2.0, 0.0], [0.0, 3.0, 0.0]]
```

#### 23. Total a uint64 array through a local accumulator. What stops it, and what gets past it? (★★★)

`hint: a literal has no width of its own`

```ruby
source = CArray.uint64(2).seq!(1)
out = CArray.uint64(1)

CArray.jit_for(1) { |i|
  total = 0
  (0...2).each { |j| total = total + source[j] }
  out[i] = total
}
#=> CArray::JIT::Unsupported: `total` enters this loop as an Integer and comes
#   back round as a uint64; the value carried to the next pass would change
#   type, and one C variable is one type -- give it one type before the loop
```

```ruby
seed = CScalar.uint64() { 0 }       # a value with a data type

CArray.jit_for(1) { |i|
  total = seed
  (0...2).each { |j| total = total + source[j] }
  out[i] = total
}
out.to_a                            #=> [3]
```

#### 24. Suffix sums: `out[i] = a[i] + out[i+1]`, with `out[4]` already set (★★★)

`hint: which way does the loop have to run, and where do you say so?`

```ruby
a = CA_DOUBLE([1, 2, 3, 4, 5])
out = CArray.double(5)
out[4] = a[4]

CArray.jit_for(3.step(0, -1)) { |i| out[i] = a[i] + out[i + 1] }
out.to_a                            #=> [15.0, 14.0, 12.0, 9.0, 5.0]
```

```ruby
out = CArray.double(5)
out[4] = a[4]

CArray.jit_for(0...4) { |i| out[i] = a[i] + out[i + 1] }
out.to_a                            #=> [1.0, 2.0, 3.0, 9.0, 5.0]
# the extent is the only place the direction is stated, and stating it
# wrongly is not refused: every cell read the zero that was still there
```

#### 25. The longest run of 1s in a series of 0s and 1s (★★★)

`hint: two things have to survive the iteration, and neither is a sum`

```ruby
flag = CA_INT32([0, 1, 1, 1, 0, 1, 1, 0])
run = CScalar.int32() { 0 }
best = CScalar.int32() { 0 }

CArray.jit_for(8) { |i|
  run[] = flag[i] == 1 ? run[] + 1 : 0
  best[] = run[] if run[] > best[]
}
best[0]                             #=> 3
```

#### 26. For each query, write the index of the last grid point not above it into `found` (★★★)

`hint: the grid is sorted`

```ruby
grid = CA_DOUBLE([0, 1, 4, 9, 16])
query = CA_DOUBLE([0.5, 5.0, 9.0, 12.0])
found = CArray.int32(4)

CArray.jit_for(4) { |i|
  t = query[i]
  low = 0
  high = 4
  while high - low > 1
    middle = (low + high) / 2
    if grid[middle] > t
      high = middle
    else
      low = middle
    end
  end
  found[i] = low
}
found.to_a                          #=> [0, 2, 3, 3]
```

#### 27. Count up to `bound[i]`, read from an array. What stops it, and what gets past it? (★★★)

`hint: an inner range is known before the loop runs`

```ruby
bound = CA_INT32([2, 3])
out = CArray.int32(2)

CArray.jit_for(2) { |i|
  count = 0
  (0...bound[i]).each { |j| count = count + 1 }
  out[i] = count
}
#=> CArray::JIT::Unsupported: an inner loop's range is an integer expression
#   over literals, captured scalars and the indices around it
```

```ruby
CArray.jit_for(2) { |i|
  count = 0
  j = 0
  while j < bound[i]                # `while` carries a bound the data decides
    count = count + 1
    j = j + 1
  end
  out[i] = count
}
out.to_a                            #=> [2, 3]
```

#### 28. Write the square of a complex array into `squared`, and the magnitude of the original into `size` (★★☆)

`hint: a data type like the others`

```ruby
z = CA_CMPLX128([Complex(0, 1), Complex(1, 1)])
squared = CArray.cmplx128(2)
size = CArray.double(2)

CArray.jit_each { squared = z * z }
CArray.jit_each { size = z.abs }

squared.to_a                        #=> [(-1.0+0.0i), (0.0+2.0i)]
size.to_a                           #=> [1.0, 1.4142135623730951]
```

#### 29. Fill an array with a hundred thousand random numbers in [0, 1), drawn inside the kernel (★★☆)

`hint: not Ruby's rand -- the loop runs without the GVL`

```ruby
random = CArray::Rng.new(seed: 3)
draws = CArray.double(100_000)

CArray.jit_for(100_000) { |i| draws[i] = random.random }
draws.mean.round(4)                 #=> 0.5006
# which draw lands in which cell is the loop's order; where that matters,
# fill an array with CArray#random! first and read a cell of it
```

#### 30. A local holds an int32 cell and is squared into an int64 array. What C type did it get? (★★★)

`hint: read what was compiled`

```ruby
source = CArray.int32(4).seq!(1)
out = CArray.int64(4)

kernel = CArray.jit_for(4) { |i|
  v = source[i]
  out[i] = v * v
}

kernel.c_source.lines.grep(/int64_t v;/).first.strip
#=> "int64_t v;"
# and the assignment below it:
#   v = (int64_t)*(int32_t *)(p_source + (i) * source_s0);
# nothing in `v = source[i]` asked for 64 bits: a local's type is settled
# from the whole body, and `v * v` lands in an int64 array
```

---

Where to go next: [06_Cheatsheet.md](06_Cheatsheet.md) to look things up,
[examples/features/](../examples/features) for a tour of one feature per file,
and [examples/applications/](../examples/applications) for programs that use
all of this to do something -- `mandelbrot.rb` is a loop like 16 whose
length no cell shares, `alarm.rb` is 25 with hysteresis, `lookup.rb` is 26
against half a million queries, `sieve.rb` is 27 from the other side.
