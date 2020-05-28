class Forest::Frame
  class Ping < Frame
    property streamIdentifier : Int32
    property ack : Bool?

    def initialize(@streamIdentifier : Int32)
      @ack = nil
    end

    def to_io(io : IO, pong_length = 8_i32)
      Frame.write_length_type io, pong_length, Ping.type
      Ping.write_flag io, ack
      Frame.write_stream_identifier io, streamIdentifier

      io.write Bytes.new pong_length
    end

    def self.from_io(io : IO, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : Continuation
      length, _type = Frame.parse_length_type io
      raise MismatchFrame.new "Mismatch Type" if Ping.type != Type.new _type.to_u8

      from_io io, length, maximum_frame_size
    end

    def self.from_io(io : IO, length : Int32, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : Ping
      # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

      if length > maximum_frame_size
        message = String.build do |io|
          io << "Frame length exceeds SETTINGS_MAX_FRAME_SIZE " << (length - maximum_frame_size) << " Bytes"
        end

        raise IllegalLength.new message
      end

      # * The PING frame defines the following flags:
      # * ACK (0x1): When set, bit 0 indicates that this PING frame is a PING response.
      #   * An endpoint MUST set this flag in PING responses.
      #   * An endpoint MUST NOT respond to PING frames containing this flag.

      flags = io.read_byte || 0_u8
      ack = (flags & 0b00000001_u8).zero? ? false : true

      # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.
      # * Stream Identifier: A stream identifier (see Section 5.1.1) expressed as an unsigned 31-bit integer.
      #   * The value 0x0 is reserved for frames that are associated with the connection as a whole as opposed to an individual stream.

      stream_identifier = Frame.parse_stream_identifier io

      # * PING frames are not associated with any individual stream. If a PING frame is received with a stream identifier field value other than 0x0, the recipient MUST respond with a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
      #   * Receipt of a PING frame with a length field value other than 8 MUST be treated as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.

      io.skip length

      # * (I.e. uselessPong ({{length}} Bytes))

      length -= length

      # * Create Frame

      ping = new stream_identifier
      ping.ack = ack

      ping
    end

    def self.write_flag(io : IO, ack : Bool?)
      flags = 0b00000000_i32
      flags = flags | (!!ack ? 0b00000001_i32 : 0b00000000_i32)

      io.write Bytes[flags]
    end

    def self.type
      Type::Ping
    end
  end
end
