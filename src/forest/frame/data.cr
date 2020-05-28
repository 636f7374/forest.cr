class Forest::Frame
  class Data < Frame
    property streamIdentifier : Int32
    property payload : Bytes
    property endStream : Bool?
    property padded : Bool?
    property paddingLength : UInt8?
    property paddingData : Bytes?

    def initialize(@streamIdentifier : Int32, @payload : Bytes)
      @endStream = nil
      @padded = nil
      @paddingLength = nil
      @paddingData = nil
    end

    def length : Int32
      padding_length = paddingLength
      length = payload.size

      if padded && padding_length
        length += 1_i32
        length += padding_length
      end

      length
    end

    def to_io(io : IO, padding_data : Bytes? = self.paddingData)
      padding_length = paddingLength
      length = payload.size

      if padded && padding_length
        length += 1_i32
        length += padding_length
      end

      Frame.write_length_type io, length, Data.type
      Data.write_flag io, endStream, padded
      Frame.write_stream_identifier io, streamIdentifier

      if padded && padding_length
        io.write Bytes[padding_length]
      end

      io.write payload

      if padded && padding_length
        Frame.write_padding io, padding_length, padding_data
      end
    end

    def self.from_io(io : IO, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : Data
      length, _type = Frame.parse_length_type io
      raise MismatchFrame.new "Mismatch Type" if Data.type != Type.new _type.to_u8

      from_io io, length, maximum_frame_size
    end

    def self.from_io(io : IO, length : Int32, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : Data
      # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

      if length > maximum_frame_size
        message = String.build do |io|
          io << "Frame length exceeds SETTINGS_MAX_FRAME_SIZE " << (length - maximum_frame_size) << " Bytes"
        end

        raise IllegalLength.new message
      end

      # * The DATA frame defines the following flags:
      # * END_STREAM (0x1): When set, bit 0 indicates that this frame is the last that the endpoint will send for the identified stream. Setting this flag causes the stream to enter one of the "half-closed" states or the "closed" state (Section 5.1).
      # * PADDED (0x8): When set, bit 3 indicates that the Pad Length field and any padding that it describes are present.

      flags = io.read_byte || 0_u8
      end_stream = (flags & 0b00000001_u8).zero? ? false : true
      padded = (flags & 0b00001000_u8).zero? ? false : true

      # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.
      # * Stream Identifier: A stream identifier (see Section 5.1.1) expressed as an unsigned 31-bit integer.
      #   * The value 0x0 is reserved for frames that are associated with the connection as a whole as opposed to an individual stream.

      stream_identifier = Frame.parse_stream_identifier io

      # * Padding Length: An 8-bit field containing the length of the frame padding in units of octets.
      #   * This field is only present if the PADDED flag is set.

      if padded
        padding_length = io.read_byte

        # * (I.e. Padding Length (1 Bytes))
        length -= 1_i32
      end

      # * Data: Application data. The amount of data is the remainder of the frame payload after subtracting the length of the other fields that are present.

      payload = Frame.read_bytes io, length

      # * Padding: Padding octets that contain no application semantic value. Padding octets MUST be set to zero when sending.
      #   * A receiver is not obligated to verify padding but MAY treat non-zero padding as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.

      if padding_length
        io.skip padding_length

        # * (I.e. Padding ({{Padding Length}} Bytes))
        length -= padding_length
      end

      # * Create Frame

      data = new stream_identifier, payload
      data.endStream = end_stream
      data.padded = padded
      data.paddingLength = padding_length

      data
    end

    def self.write_flag(io : IO, end_stream : Bool?, padded : Bool?)
      end_stream = true if end_stream.nil?

      flags = 0b00000000_u8
      flags = flags | (!!padded ? 0b00001000_i32 : 0b00000000_i32)
      flags = flags | (!!end_stream ? 0b00000001_i32 : 0b00000000_i32)

      io.write Bytes[flags]
    end

    def self.type
      Type::Data
    end
  end
end
