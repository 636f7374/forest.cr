class Forest::Frame
  class Settings < Frame
    enum Parameter : UInt16
      HeaderTableSize      = 1_u16
      EnablePush           = 2_u16
      MaxConcurrentStreams = 3_u16
      InitialWindowSize    = 4_u16
      MaxFrameSize         = 5_u16
      MaxHeaderListSize    = 6_u16
    end

    property streamIdentifier : Int32
    property settings : Array(Tuple(Parameter, Int32))?
    property ack : Bool?

    def initialize(@streamIdentifier : Int32, @settings : Array(Tuple(Parameter, Int32))?)
      @ack = nil
    end

    def to_io(io : IO)
      length = (settings.try &.size || 0_i32) * 6_i32

      Frame.write_length_type io, length, Settings.type
      Settings.write_flag io, ack
      Frame.write_stream_identifier io, streamIdentifier

      settings.try &.each do |item|
        name, value = item

        io.write_bytes name.value, IO::ByteFormat::BigEndian
        io.write_bytes value, IO::ByteFormat::BigEndian
      end
    end

    def self.from_io(io : IO, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : Settings
      length, _type = Frame.parse_length_type io
      raise MismatchFrame.new "Mismatch Type" if Settings.type != Type.new _type.to_u8

      from_io io, length, maximum_frame_size
    end

    def self.from_io(io : IO, length : Int32, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : Settings
      # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

      if length > maximum_frame_size
        message = String.build do |io|
          io << "Frame length exceeds SETTINGS_MAX_FRAME_SIZE " << (length - maximum_frame_size) << " Bytes"
        end

        raise IllegalLength.new message
      end

      # * SETTINGS parameters are acknowledged by the receiving peer. To enable this, the SETTINGS frame defines the following flag:
      # * ACK (0x1): When set, bit 0 indicates that this frame acknowledges receipt and application of the peer's SETTINGS frame.
      #   * When this bit is set, the payload of the SETTINGS frame MUST be empty.
      #   * Receipt of a SETTINGS frame with the ACK flag set and a length field value other than 0 MUST be treated as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
      #   * For more information, see Section 6.5.3 ("Settings Synchronization").

      flags = io.read_byte || 0_u8
      ack = (flags & 0b00000001_u8).zero? ? false : true

      # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.
      # * Stream Identifier: A stream identifier (see Section 5.1.1) expressed as an unsigned 31-bit integer.
      #   * The value 0x0 is reserved for frames that are associated with the connection as a whole as opposed to an individual stream.

      stream_identifier = Frame.parse_stream_identifier io

      # * The following parameters are defined:
      # * SETTINGS_HEADER_TABLE_SIZE (0x1):
      #   * Allows the sender to inform the remote endpoint of the maximum size of the header compression table used to decode header blocks, in octets. The encoder can select any size equal to or less than this value by using signaling specific to the header compression format inside a header block (see [COMPRESSION]). The initial value is 4,096 octets.
      # * SETTINGS_ENABLE_PUSH (0x2):
      #   * This setting can be used to disable server push (Section 8.2). An endpoint MUST NOT send a PUSH_PROMISE frame if it receives this parameter set to a value of 0. An endpoint that has both set this parameter to 0 and had it acknowledged MUST treat the receipt of a PUSH_PROMISE frame as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
      #   * The initial value is 1, which indicates that server push is permitted. Any value other than 0 or 1 MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
      # * SETTINGS_MAX_CONCURRENT_STREAMS (0x3):
      #   * Indicates the maximum number of concurrent streams that the sender will allow. This limit is directional: it applies to the number of streams that the sender permits the receiver to create. Initially, there is no limit to this value. It is recommended that this value be no smaller than 100, so as to not unnecessarily limit parallelism.
      #   * A value of 0 for SETTINGS_MAX_CONCURRENT_STREAMS SHOULD NOT be treated as special by endpoints. A zero value does prevent the creation of new streams; however, this can also happen for any limit that is exhausted with active streams. Servers SHOULD only set a zero value for short durations; if a server does not wish to accept requests, closing the connection is more appropriate.
      # * SETTINGS_INITIAL_WINDOW_SIZE (0x4):
      #   * Indicates the sender's initial window size (in octets) for stream-level flow control. The initial value is 216-1 (65,535) octets.
      #   * This setting affects the window size of all streams (see Section 6.9.2).
      #   * Values above the maximum flow-control window size of 231-1 MUST be treated as a connection error (Section 5.4.1) of type FLOW_CONTROL_ERROR.
      # * SETTINGS_MAX_FRAME_SIZE (0x5):
      #   * Indicates the size of the largest frame payload that the sender is willing to receive, in octets.
      #   * The initial value is 214 (16,384) octets. The value advertised by an endpoint MUST be between this initial value and the maximum allowed frame size (224-1 or 16,777,215 octets), inclusive. Values outside this range MUST be treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
      # * SETTINGS_MAX_HEADER_LIST_SIZE (0x6):
      #   * This advisory setting informs a peer of the maximum size of header list that the sender is prepared to accept, in octets. The value is based on the uncompressed size of header fields, including the length of the name and value in octets plus an overhead of 32 octets for each header field.
      #   * For any given request, a lower limit than what is advertised MAY be enforced. The initial value of this setting is unlimited.

      settings = [] of Tuple(Parameter, Int32)

      # * The payload of a SETTINGS frame consists of zero or more parameters, each consisting of an unsigned 16-bit setting identifier and an unsigned 32-bit value.

      (length // 6_i32).times do |time|
        name = Parameter.new io.read_bytes UInt16, IO::ByteFormat::BigEndian
        value = io.read_bytes Int32, IO::ByteFormat::BigEndian

        settings << Tuple.new name, value
      end

      # * (I.e. Length - Settings ({{(2 Bytes: name, 4 Bytes: value)}}))

      length -= 6_i32 * (length // 6_i32)

      # * Create Frame

      settings = new stream_identifier, settings
      settings.ack = ack

      settings
    end

    def self.write_flag(io : IO, ack : Bool?)
      flags = 0b00000000_i32
      flags = flags | (!!ack ? 0b00000001_i32 : 0b00000000_i32)

      io.write Bytes[flags]
    end

    def self.type
      Type::Settings
    end
  end
end
