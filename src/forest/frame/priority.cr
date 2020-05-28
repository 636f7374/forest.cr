class Forest::Frame
  class Priority < Frame
    property streamIdentifier : Int32
    property exclusive : Bool
    property streamDependency : Int32
    property weight : UInt8

    def initialize(@streamIdentifier : Int32, @exclusive : Bool, @streamDependency : Int32, @weight : UInt8)
    end

    def to_io(io : IO)
      Frame.write_length_type io, 5_i32, Priority.type
      Priority.write_flag io
      Frame.write_stream_identifier io, streamIdentifier
      Frame.write_exclusive_stream_dependency io, streamDependency

      io.write Bytes[weight]
    end

    def self.from_io(io : IO, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : Priority
      length, _type = Frame.parse_length_type io
      raise MismatchFrame.new "Mismatch Type" if Priority.type != Type.new _type.to_u8

      from_io io, length, maximum_frame_size
    end

    def self.from_io(io : IO, length : Int32, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : Priority
      # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

      if length > maximum_frame_size
        message = String.build do |io|
          io << "Frame length exceeds SETTINGS_MAX_FRAME_SIZE " << (length - maximum_frame_size) << " Bytes"
        end

        raise IllegalLength.new message
      end

      # * The PRIORITY frame does not define any flags.

      unused_flag = io.skip 1_i32

      # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.
      # * Stream Identifier: A stream identifier (see Section 5.1.1) expressed as an unsigned 31-bit integer.
      #   * The value 0x0 is reserved for frames that are associated with the connection as a whole as opposed to an individual stream.

      stream_identifier = Frame.parse_stream_identifier io

      # * Exclusive: A single-bit flag indicating that the stream dependency is exclusive (see Section 5.3).
      #   * This field is only present if the PRIORITY flag is set.
      # * Stream Dependency: A 31-bit stream identifier for the stream that this stream depends on (see Section 5.3).
      #   * This field is only present if the PRIORITY flag is set.

      exclusive_stream_dependency = Frame.parse_exclusive_stream_dependency io
      _exclusive, stream_dependency = exclusive_stream_dependency
      exclusive = _exclusive.zero? ? false : true

      # * Weight: An unsigned 8-bit integer representing a priority weight for the stream (see Section 5.3).
      #   * Add one to the value to obtain a weight between 1 and 256.
      #   * This field is only present if the PRIORITY flag is set.

      weight = io.read_byte || 0_u8

      # * (I.e. Length - exclusiveStreamDependency (4 Bytes) & weight (1 Bytes))

      length -= 5_i32

      # * Create Frame

      new stream_identifier, exclusive, stream_dependency, weight
    end

    def self.write_flag(io : IO)
      # * The PRIORITY frame does not define any flags.

      io.write Bytes[0_i32]
    end

    def self.type
      Type::Priority
    end
  end
end
