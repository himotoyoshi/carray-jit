# Branches, and asking whether a cell is missing

`if` works in statement position, so a kernel can decide what to write:

```ruby
CArray.jit_for(n) { |i|
  if source[i] == UNDEF
    result[i] = 0.0
  else
    result[i] = Math.sqrt(source[i])
  end
}
```

`a[i] == UNDEF` is how Ruby already asks whether a cell is missing, and it
means the same here. It compiles to a read of the mask byte, never of the
value. `a[i] = UNDEF` marks a cell missing, and leaves its bytes alone.
Mentioning UNDEF at all makes the kernel a masked one, whatever its arrays
happen to carry.

This is only cheap because the subset is CArray's, not Ruby's: `== UNDEF`
does not have to be a general comparison against a general value, it can be
an idiom with a meaning of its own.

It also settles a question the implicit propagation cannot. Asking about the
mask is not reading the value, so it carries no mask into what the branch
writes -- which is what makes filling a hole possible:

```ruby
if source[i] == UNDEF
  result[i] = 0.0          # no cell was read; the result is present
else
  result[i] = source[i]    # a value was read, but not a masked one
end
```

Reading the *value* still propagates, including in a condition: a branch taken
on `source[i] > 0.0` where `source[i]` is masked was decided by garbage, so
what it writes is masked.

And it brings the reference back. A masked kernel written this way can be
checked against the same loop written in Ruby, which a kernel relying on
implicit propagation cannot be -- `source[i]` hands Ruby an UNDEF, and
`UNDEF * 2.0` does not run.

A branch with no `else` writes nothing on the path not taken, so the cell
keeps both its value and its mask -- as the same `if` would in Ruby. As an
*expression*, `if` still needs an `else`, because there every cell needs a
value.

`next` and `break` work in an inner loop, which is how a search is written:

```ruby
CArray.jit_for(rows) { |i|
  found = -1
  (0...columns).each { |j|
    if source[i, j] > threshold
      found = j
      break
    end
  }
  first[i] = found
}
```

`next` in the kernel block skips the cell, the way it would end a block Ruby
was running: the cell keeps its value and its mask, and the loop moves on.

`break` in the kernel block is refused. Ruby's `break` in a block is not a
loop exit but a return from the method the block was passed to, carrying a
value, and the value is one this cannot produce. `break x` and `next x` are
refused for the same kind of reason: the inner loop's own value is never used,
so a value would be dropped silently.

An `each` with a `break` in it is what a `while` would have been, and it is
still the better way to write a loop whose bound you know: the bound sits in
the extent, so the kernel cannot fail to stop, and a cell that ran out of
iterations can be told from one that converged.

```ruby
CArray.jit_for(n) { |i|
  x = a[i]
  taken = 0
  (0...cap).each { |k|                       # cap is an ordinary local
    break if (x * x - a[i]).abs <= tolerance * a[i]
    x = 0.5 * (x + a[i] / x)
    taken = taken + 1
  }
  root[i] = x
  passes[i] = taken                          # 0 means it was already there
}
```

That is bit-for-bit the same as the Ruby `while` loop it replaces, iteration
counts included, and about 38x faster over 200,000 cells.

## while

Where the bound is not knowable, `while` says so:

```ruby
CArray.jit_for(n) { |i|
  guess = a[i]
  while (guess * guess - a[i]).abs > tolerance
    guess = 0.5 * (guess + a[i] / guess)
  end
  root[i] = guess
}
```

The condition is read at the top of every pass, as Ruby's is, and `next` and
`break` mean inside it what they mean inside an inner loop. A local the
condition reads has to be a local before the loop: the condition is read
before the body is, so a name only the body assigns is not in scope where the
condition wants it, and says so rather than reading whatever C left in the
variable. `begin ... end while` is refused -- it is the one loop in Ruby that
tests after the body, and a reader who missed the `begin` would take the first
pass for a conditional one.

What it gives up is the guarantee that the loop ends. Nothing here can decide
that in general, and no invented bound would help: a cap the compiler chose
would be a number nobody could choose, and the loops whose bound *is*
knowable already have the spelling above. So this is C's bargain, the same one
a `jit_function` that recurses too deep already takes.

It bites harder than the equivalent mistake in Ruby. A kernel that does not
return cannot be interrupted: the generated loop has no interrupt check in it,
a signal is handled on the main thread, and the main thread is inside the
call. `Ctrl-C` is not delivered until the call returns, and that is true
whether or not the GVL is held -- releasing it lets *other* threads run, which
`jit_for` does, but it does not give the running loop a place to notice a
signal. A runaway pass ends with a signal from another terminal.

The one case that can be read off the page is refused rather than compiled:

```ruby
while true            # with no `break` and no `raise` in the body
  ...
end
```

That is not a guess about the data -- the condition is never going to be
false and the body holds no way out -- so refusing it costs no program that
would have worked. `while true` with a `break` in it is an ordinary thing to
write and is left alone.

A loop entered on a value read from a missing cell is in the position a branch
taken on one is in, and is treated the same way: it was decided by bytes that
mean nothing, so what the body writes is masked. Running on those bytes costs
more here than it does in a branch, though -- garbage decides how many passes
there are -- so a kernel whose loop condition reads a cell that may be missing
should say so with `if a[i] == UNDEF`, which is the advice masked arithmetic
already gets.

`until` is not in the subset. `while` with the condition negated is the same
loop, and one spelling of it is enough to keep.

Neither costs anything here. An inner loop carrying a `break` is not a fold
and so is not split into partial sums to begin with -- it stays the serial
chain it always was -- and a `next` in the kernel block is if-converted like
any other branch: a per-cell loop with an `if` in it still compiles to
`fadd.2d` and `fcmgt.2d` on the contiguous path.
