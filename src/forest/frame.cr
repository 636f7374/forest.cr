abstract class Forest::Frame
  enum Error : UInt32
    NoError            =  0_u32
    ProtocolError      =  1_u32
    InternalError      =  2_u32
    FlowControlError   =  3_u32
    SettingsTimeOut    =  4_u32
    StreamClosed       =  5_u32
    FrameSizeError     =  6_u32
    RefusedStream      =  7_u32
    Cancel             =  8_u32
    CompressionError   =  9_u32
    ConnectError       = 10_u32
    EnhanceYourCalm    = 11_u32
    InadequateSecurity = 12_u32
    Http11Required     = 13_u32
  end

  enum Type : UInt8
    Data         = 0_u8
    Headers      = 1_u8
    Priority     = 2_u8
    RstStream    = 3_u8
    Settings     = 4_u8
    PushPromise  = 5_u8
    Ping         = 6_u8
    GoAway       = 7_u8
    WindowUpdate = 8_u8
    Continuation = 9_u8
  end

  abstract def streamIdentifier : Int32

  def self.from_io(io : IO, continuation : Bool = false, hpack_decoder : Hpack::Decoder? = nil, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE,
                   maximum_header_continuation_size : Int32 = MAX_HEADER_CONTINUATION_SIZE) : Frame
    # * Length: The length of the frame payload expressed as an unsigned 24-bit integer.
    #   * Values greater than 214 (16,384) MUST NOT be sent unless the receiver has set a larger value for SETTINGS_MAX_FRAME_SIZE.
    #   * The 9 octets of the frame header are not included in this value.
    # * Type: The 8-bit type of the frame. The frame type determines the format and semantics of the frame.
    #   * Implementations MUST ignore and discard any frame that has a type that is unknown.

    length, _type = Frame.parse_length_type io

    case Type.new _type.to_u8
    when .data?
      # DATA frames (type=0x0) convey arbitrary, variable-length sequences of octets associated with a stream. One or more DATA frames are used, for instance, to carry HTTP request or response payloads.

      Data.from_io io: io, length: length, maximum_frame_size: maximum_frame_size
    when .headers?
      # The HEADERS frame (type=0x1) is used to open a stream (Section 5.1), and additionally carries a header block fragment. HEADERS frames can be sent on a stream in the "idle", "reserved (local)", "open", or "half-closed (remote)" state.

      Headers.from_io io: io, length: length, continuation: continuation, hpack_decoder: hpack_decoder, maximum_frame_size: maximum_frame_size, maximum_header_continuation_size: maximum_header_continuation_size
    when .priority?
      # The PRIORITY frame (type=0x2) specifies the sender-advised priority of a stream (Section 5.3). It can be sent in any stream state, including idle or closed streams.

      Priority.from_io io: io, length: length, maximum_frame_size: maximum_frame_size
    when .rst_stream?
      # The RST_STREAM frame (type=0x3) allows for immediate termination of a stream. RST_STREAM is sent to request cancellation of a stream or to indicate that an error condition has occurred.

      RstStream.from_io io: io, length: length, maximum_frame_size: maximum_frame_size
    when .settings?
      # The SETTINGS frame (type=0x4) conveys configuration parameters that affect how endpoints communicate, such as preferences and constraints on peer behavior. The SETTINGS frame is also used to acknowledge the receipt of those parameters. Individually, a SETTINGS parameter can also be referred to as a "setting".

      Settings.from_io io: io, length: length, maximum_frame_size: maximum_frame_size
    when .push_promise?
      # The PUSH_PROMISE frame (type=0x5) is used to notify the peer endpoint in advance of streams the sender intends to initiate. The PUSH_PROMISE frame includes the unsigned 31-bit identifier of the stream the endpoint plans to create along with a set of headers that provide additional context for the stream. Section 8.2 contains a thorough description of the use of PUSH_PROMISE frames.

      PushPromise.from_io io: io, length: length, continuation: continuation, hpack_decoder: hpack_decoder, maximum_frame_size: maximum_frame_size, maximum_header_continuation_size: maximum_header_continuation_size
    when .ping?
      # The PING frame (type=0x6) is a mechanism for measuring a minimal round-trip time from the sender, as well as determining whether an idle connection is still functional. PING frames can be sent from any endpoint.

      Ping.from_io io: io, length: length, maximum_frame_size: maximum_frame_size
    when .go_away?
      # The GOAWAY frame (type=0x7) is used to initiate shutdown of a connection or to signal serious error conditions. GOAWAY allows an endpoint to gracefully stop accepting new streams while still finishing processing of previously established streams. This enables administrative actions, like server maintenance.

      GoAway.from_io io: io, length: length, maximum_frame_size: maximum_frame_size
    when .window_update?
      # The WINDOW_UPDATE frame (type=0x8) is used to implement flow control; see Section 5.2 for an overview.

      WindowUpdate.from_io io: io, length: length, maximum_frame_size: maximum_frame_size
    when .continuation?
      # The CONTINUATION frame (type=0x9) is used to continue a sequence of header block fragments (Section 4.3). Any number of CONTINUATION frames can be sent, as long as the preceding frame is on the same stream and is a HEADERS, PUSH_PROMISE, or CONTINUATION frame without the END_HEADERS flag set.

      Continuation.from_io io: io, length: length, hpack_decoder: hpack_decoder, maximum_frame_size: maximum_frame_size
    else
      raise UnexpectedFrame.new String.build { |io| io << "Unknown Flag: " << _type.to_u8 }
    end
  end

  {% for name in ["stream_identifier", "window_size_increment", "promised_stream_id"] %}
  def self.parse_{{name.id}}(io : IO) : Int32
    reserved_{{name.id}} = io.read_bytes UInt32, IO::ByteFormat::BigEndian
    reserved, {{name.id}} = reserved_{{name.id}}.bit(31_i32), (reserved_{{name.id}} & 0x7fffffff_u32).to_i32

    {{name.id}}
  end
  {% end %}

  {% for name in ["exclusive_stream_dependency"] %}
  def self.parse_{{name.id}}(io : IO) : Tuple(UInt32, Int32)
    {{name.id}} = io.read_bytes UInt32, IO::ByteFormat::BigEndian
    Tuple.new {{name.id}}.bit(31_i32), ({{name.id}} & 0x7fffffff_u32).to_i32
  end
  {% end %}

  def self.parse_length_type(io : IO) : Tuple(Int32, UInt32)
    length_type = io.read_bytes UInt32, IO::ByteFormat::BigEndian
    Tuple.new (length_type >> 8_i32).to_i, length_type & 0xff_i32
  end

  def self.write_length_type(io : IO, length : Int32, type : Type)
    io.write_bytes (length << 8_i32) | type.value, IO::ByteFormat::BigEndian
  end

  {% for name in ["stream_identifier", "window_size_increment", "promised_stream_id", "exclusive_stream_dependency"] %}
  def self.write_{{name.id}}(io : IO, {{name.id}} : Int32)
    # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.

    reserved = 0b00000000000000000000000000000000_i32
    #            ^ 

    {{name.id}} = {{name.id}} | reserved

    io.write_bytes {{name.id}}, IO::ByteFormat::BigEndian
  end
  {% end %}

  def self.write_error(io : IO, error : Error)
    io.write_bytes error.value, IO::ByteFormat::BigEndian
  end

  def self.write_padding(io : IO, padding_length : UInt8, data : Bytes? = nil)
    if data && ((data.size < padding_length) || (data.size > padding_length))
      data = Bytes.new padding_length
    end

    io.write data || Bytes.new padding_length
  end

  def self.read_bytes(io, size : Int32)
    pointer = GC.malloc_atomic(size).as UInt8*
    io.read_fully pointer.to_slice(size)

    pointer.to_slice size
  end
end

require "./hpack.cr"
require "./frame/*"
