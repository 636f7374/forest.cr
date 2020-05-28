class Forest::Frame
  class RstStream < Frame
    property streamIdentifier : Int32
    property error : Error

    def initialize(@streamIdentifier : Int32, @error : Error = Error::NoError)
    end

    def to_io(io : IO)
      Frame.write_length_type io, 4_i32, RstStream.type
      RstStream.write_flag io
      Frame.write_stream_identifier io, streamIdentifier
      Frame.write_error io, error
    end

    def self.from_io(io : IO, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : RstStream
      length, _type = Frame.parse_length_type io
      raise MismatchFrame.new "Mismatch Type" if RstStream.type != Type.new _type.to_u8

      from_io io, length, maximum_frame_size
    end

    def self.from_io(io : IO, length : Int32, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : RstStream
      # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

      if length > maximum_frame_size
        message = String.build do |io|
          io << "Frame length exceeds SETTINGS_MAX_FRAME_SIZE " << (length - maximum_frame_size) << " Bytes"
        end

        raise IllegalLength.new message
      end

      # * The RST_STREAM frame does not define any flags.

      unused_flag = io.skip 1_i32

      # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.
      # * Stream Identifier: A stream identifier (see Section 5.1.1) expressed as an unsigned 31-bit integer.
      #   * The value 0x0 is reserved for frames that are associated with the connection as a whole as opposed to an individual stream.

      stream_identifier = Frame.parse_stream_identifier io

      # * The RST_STREAM frame contains a single unsigned, 32-bit integer identifying the error code (Section 7).
      #   * The error code indicates why the stream is being terminated.

      error = Error.new io.read_bytes UInt32, IO::ByteFormat::BigEndian

      # * (I.e. Length - Error (4 Bytes))

      length -= 4_i32

      # * Create Frame

      new stream_identifier, error
    end

    def self.write_flag(io : IO)
      # * The RST_STREAM frame does not define any flags.

      io.write Bytes[0_i32]
    end

    def self.type
      Type::RstStream
    end
  end
end
