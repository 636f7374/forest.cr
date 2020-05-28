class Forest::Frame
  class Continuation < Frame
    property streamIdentifier : Int32
    property fragment : Bytes
    property endHeaders : Bool?

    def initialize(@streamIdentifier : Int32, @fragment : Bytes)
      @endHeaders = nil
    end

    def to_io(io : IO, payload : Bytes)
      Frame.write_length_type io, payload.size, Continuation.type
      Continuation.write_flag io, endHeaders
      Frame.write_stream_identifier io, streamIdentifier

      io.write payload
    end

    def to_io(io : IO)
      to_io io, fragment
    end

    def self.from_io(io : IO, hpack_decoder : Hpack::Decoder? = nil, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : Continuation
      length, _type = Frame.parse_length_type io
      raise MismatchFrame.new "Mismatch Type" if Continuation.type != Type.new _type.to_u8

      from_io io, length, hpack_decoder, maximum_frame_size
    end

    def self.from_io(io : IO, length : Int32, hpack_decoder : Hpack::Decoder? = nil, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : Continuation
      # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

      if length > maximum_frame_size
        message = String.build do |io|
          io << "Frame length exceeds SETTINGS_MAX_FRAME_SIZE " << (length - maximum_frame_size) << " Bytes"
        end

        raise IllegalLength.new message
      end

      # * The HEADERS frame defines the following flags:
      # * END_HEADERS (0x4): When set, bit 2 indicates that this frame contains an entire header block (Section 4.3) and is not followed by any CONTINUATION frames.
      #   * A HEADERS frame without the END_HEADERS flag set MUST be followed by a CONTINUATION frame for the same stream. A receiver MUST treat the receipt of any other type of frame or a frame on a different stream as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.

      flags = io.read_byte || 0_u8
      end_headers = (flags & 0b00001000_u8).zero? ? false : true

      # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.
      # * Stream Identifier: A stream identifier (see Section 5.1.1) expressed as an unsigned 31-bit integer.
      #   * The value 0x0 is reserved for frames that are associated with the connection as a whole as opposed to an individual stream.

      stream_identifier = Frame.parse_stream_identifier io

      # * The payload of a HEADERS frame contains a header block fragment (Section 4.3).
      #   * A header block that does not fit within a HEADERS frame is continued in a CONTINUATION frame (Section 6.10).

      payload = Frame.read_bytes io, length

      # * Create Frame

      headers = new stream_identifier, payload
      headers.endHeaders = end_headers

      headers
    end

    def self.write_flag(io : IO, end_headers : Bool?)
      end_headers = true if end_headers.nil?

      flags = 0b00000000_i32
      flags = flags | (!!end_headers ? 0b00000100_i32 : 0b00000000_i32)

      io.write Bytes[flags]
    end

    def self.type
      Type::Continuation
    end
  end
end
