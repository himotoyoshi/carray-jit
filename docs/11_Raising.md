# Raising from a kernel

A kernel can stop and say why:

```ruby
CArray.jit_for(n) { |i|
  raise "depth went negative" if depth[i] < 0.0
  out[i] = Math.sqrt(depth[i])
}
```

What comes back is a `RuntimeError` with that message -- what `raise "..."`
gives in Ruby -- and the loop stops where it raised: the cell that raised is
not written, and neither are the ones after it. The cells before it keep what
the kernel wrote, as they do when a division with no divisor stops one.

The message is written out and the class is not named. Both follow from where
the message goes: C has nothing to carry a string out of a cell in, so the
message is registered as the kernel is compiled and the cell writes a code for
it into the error slot the kernel is already watching. The raise itself
happens on the Ruby side, once the loop has stopped and there is a Ruby stack
to raise on. A message the block computed would have nothing registered, and a
class is not a value the slot can carry.

A cell whose value is missing does not raise. `raise "..." if a[i] < 0` under
a mask was decided by bytes that mean nothing, and this is the rule the
division helper already keeps and that `if` keeps for what it writes.

A `jit_function` body raises the same way. It reports into the flag it
already reports a division by zero into -- the one in its own compiled object
where it stands alone, the kernel's slot where it is pasted -- and the message
travels with the function, so `f.call(-1.0)` and the same body reached from a
kernel raise the same thing. A kernel takes the messages of the bodies it
pasted as its own; the codes agree because they come from the messages.
