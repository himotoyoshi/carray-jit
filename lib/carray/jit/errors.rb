class CArray
  module JIT

    # The base of every error this gem raises.
    class Error < StandardError
    end

    # Raised when a kernel falls outside the recognized subset.  Callers that
    # want the Ruby evaluator instead of a hard failure rescue this.
    class Unsupported < Error

      # @return [Prism::Location, nil] where in the block the construct is, or
      #   `nil` when the message names no place.
      attr_reader :location

      # @param message [String] what was refused.
      # @param location [Prism::Location, nil] where it is in the block; when
      #   given, the line and column are appended to the message.
      def initialize (message, location = nil)
        @location = location
        if location
          super("#{message} (at line #{location.start_line}, column #{location.start_column})")
        else
          super(message)
        end
      end

    end

    # Raised when the C compiler rejects generated source, or the shared
    # object cannot be loaded.  Never a fallback condition -- it means the
    # generator emitted something wrong.
    class CompilationError < Error
    end

  end
end
