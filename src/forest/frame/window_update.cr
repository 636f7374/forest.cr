class Forest::Frame
  class WindowUpdate < Frame
    property streamIdentifier : Int32
    property windowSizeIncrement : Int32

    def initialize(@streamIdentifier : Int32, @windowSizeIncrement : Int32)
    end

    def to_io(io : IO)
      Frame.write_length_type io, 4_i32, WindowUpdate.type
      WindowUpdate.write_flag io
      Frame.write_stream_identifier io, streamIdentifier
      Frame.write_window_size_increment io, windowSizeIncrement
    end

    def self.from_io(io : IO, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : WindowUpdate
      length, _type = Frame.parse_length_type io
      raise MismatchFrame.new "Mismatch Type" if WindowUpdate.type != Type.new _type.to_u8

      from_io io, length, maximum_frame_size
    end

    def self.from_io(io : IO, length : Int32, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : WindowUpdate
      # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

      if length > maximum_frame_size
        message = String.build do |io|
          io << "Frame length exceeds SETTINGS_MAX_FRAME_SIZE " << (length - maximum_frame_size) << " Bytes"
        end

        raise IllegalLength.new message
      end

      # * The WINDOW_UPDATE frame does not define any flags.

      unused_flag = io.skip 1_i32

      # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.
      # * Stream Identifier: A stream identifier (see Section 5.1.1) expressed as an unsigned 31-bit integer.
      #   * The value 0x0 is reserved for frames that are associated with the connection as a whole as opposed to an individual stream.

      stream_identifier = Frame.parse_stream_identifier io

      # * The payload of a WINDOW_UPDATE frame is one reserved bit plus an unsigned 31-bit integer indicating the number of octets that the sender can transmit in addition to the existing flow-control window.
      #   * The legal range for the increment to the flow-control window is 1 to 231-1 (2,147,483,647) octets.

      window_size_increment = Frame.parse_window_size_increment io

      # * (I.e. length - windowSizeIncrement (4 Bytes))

      length -= 4_i32

      # * Create Frame

      new stream_identifier, window_size_increment
    end

    def self.write_flag(io : IO)
      # * The WINDOW_UPDATE frame does not define any flags.

      io.write Bytes[0_i32]
    end

    def self.type
      Type::WindowUpdate
    end
  end
end
