# `CArray.jit_call`, and only what defining it needs.
#
# A file that calls `jit_call` has to have the method, and having it used to
# mean loading the whole compiler -- the analyzer, the generator, the cache.
# For a program that compiles, that is what it is.  For one whose call sites
# were built ahead of it by carray-jit-aot, and where a provider answers
# every one of them, it is a compiler loaded and never reached.
#
# So this is the light half: the declaration's parser, which says what a call
# takes, and the provider, which may answer without compiling.  The compiler
# is required at the first site no provider answers, and not before.
#
# `require "carray/jit"` still loads everything, and a program that does not
# know about any of this sees no difference.

require "carray"
require "carray/jit/version"
require "carray/jit/errors"
require "carray/jit/c_function"

class CArray

  # Compiles the block as a C function and calls it, here, with the locals
  # around it:
  #
  #   def moving_average (values, window)
  #     n = values.elements
  #     out = CArray.double(n)
  #     CArray.jit_call("void (*)(double *out, const double *values, " \
  #                     "size_t n, size_t window)") {
  #       n.times { |i| ... }
  #     }
  #     out
  #   end
  #
  # The declaration's parameter names are the join, and they do the work
  # twice over: they are the body's parameters, so the block declares none,
  # and they name the locals of the method around it that the call reads.
  # In C a parameter's name in a prototype is decoration; here it is the
  # whole binding, and a name with no local behind it is an error at the
  # call rather than a `nil` inside it.
  #
  # What this saves over `jit_function` plus a `call` is the argument list --
  # written out, it is a second statement of what the declaration already
  # said, in an order nothing checks.  What it costs is reading those locals
  # through the block's binding, measured at about 0.3 microseconds against a
  # call that costs several.
  #
  # Compiled once per call site and kept, so the second call is a lookup.
  # The block is read, never yielded to; a name it closes over that is not a
  # parameter is refused, as it is for `jit_function`.
  #
  # @param prototype [String] the function's C declaration. `double (*)(...)`
  #   is the spelling for one with no name, which is what a call needs: the
  #   name would be written once to be looked at never.
  # @return [Object, nil] what the function answered, or nil where it
  #   returns `void`.
  # @raise [CArray::JIT::Unsupported] when the block falls outside the
  #   recognized subset, or names parameters the declaration already named.
  def self.jit_call (prototype, &block)
    unless block
      raise JIT::Unsupported,
            "`jit_call` compiles a block and calls it, and none was given"
    end
    JIT.call_here(prototype, block)
  end

end
