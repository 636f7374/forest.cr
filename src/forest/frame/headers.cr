class Forest::Frame
  class Headers < Frame
    property streamIdentifier : Int32
    property exclusive : Bool?
    property streamDependency : Int32?
    property weight : UInt8?
    property httpHeaders : HTTP::Headers
    property endStream : Bool?
    property endHeaders : Bool?
    property padded : Bool?
    property priority : Bool?
    property paddingLength : UInt8?
    property paddingData : Bytes?

    def initialize(@streamIdentifier : Int32, httpHeaders : HTTP::Headers?, @exclusive : Bool?,
                   @streamDependency : Int32?, @weight : UInt8?)
      @httpHeaders = httpHeaders || HTTP::Headers.new
      @endStream = nil
      @endHeaders = nil
      @padded = nil
      @priority = nil
      @paddingLength = nil
      @paddingData = nil
    end

    def self.encode(hpack_encoder : Hpack::Encoder, headers : HTTP::Headers? = self.httpHeaders)
      hpack_encoder.encode headers: headers || HTTP::Headers.new
    end

    def self.decode(hpack_decoder : Hpack::Decoder, payload : Bytes)
      hpack_decoder.decode bytes: payload.to_slice
    end

    def to_io(io : IO, payload : Bytes, padding_data : Bytes? = self.paddingData)
      padding_length = paddingLength
      length = payload.size

      if padded && padding_length
        length += 1_i32
        length += padding_length
      end

      length += 5_i32 if priority

      Frame.write_length_type io, length, Headers.type

      Headers.write_flag io, endStream, endHeaders, padded, priority
      Frame.write_stream_identifier io, streamIdentifier

      if padded && padding_length
        io.write Bytes[padding_length]
      end

      if priority
        Frame.write_exclusive_stream_dependency io, streamDependency || 0_i32
        io.write Bytes[weight || 0_u8]
      end

      io.write payload

      if padded && padding_length
        Frame.write_padding io, padding_length, padding_data
      end
    end

    def to_io(io : IO, hpack_encoder : Hpack::Encoder? = nil, padding_data : Bytes? = self.paddingData, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE)
      maximum_headers_frame_size = maximum_frame_size.dup

      maximum_headers_frame_size -= 5_i32 if priority
      padding_length = paddingLength

      if padded && padding_length
        maximum_headers_frame_size -= 1_i32
        maximum_headers_frame_size -= padding_length
      end

      payload = Headers.encode hpack_encoder, httpHeaders

      if payload.size <= maximum_headers_frame_size
        self.endHeaders = true
        to_io io, payload, padding_data

        return
      end

      self.endHeaders = false
      to_io io, payload[0_i32..maximum_headers_frame_size - 1_i32], padding_data

      remaining_slice = payload[maximum_headers_frame_size...]
      remaining_memory = IO::Memory.new remaining_slice
      remaining_size = remaining_memory.size

      loop do
        break if remaining_size.zero?
        pointer = GC.malloc_atomic(maximum_frame_size).as UInt8*

        length = remaining_memory.read pointer.to_slice(maximum_frame_size)
        break if (0_i32 > length) || length.zero?

        continuation = Continuation.new streamIdentifier: streamIdentifier, fragment: pointer.to_slice(length)
        continuation.endHeaders = false if remaining_size > maximum_frame_size
        continuation.to_io io: io

        remaining_size -= length
      end
    end

    def self.from_io(io : IO, continuation : Bool, hpack_decoder : Hpack::Decoder? = nil, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE, maximum_header_continuation_size : Int32 = MAX_HEADER_CONTINUATION_SIZE) : Headers
      length, _type = Frame.parse_length_type io
      raise MismatchFrame.new "Mismatch Type" if Headers.type != Type.new _type.to_u8

      from_io io, length, continuation, hpack_decoder, maximum_frame_size, maximum_header_continuation_size
    end

    def self.from_io(io : IO, length : Int32, continuation : Bool, hpack_decoder : Hpack::Decoder? = nil, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE, maximum_header_continuation_size : Int32 = MAX_HEADER_CONTINUATION_SIZE) : Headers
      # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

      if length > maximum_frame_size
        message = String.build do |io|
          io << "Frame length exceeds SETTINGS_MAX_FRAME_SIZE " << (length - maximum_frame_size) << " Bytes"
        end

        raise IllegalLength.new message
      end

      # * The HEADERS frame defines the following flags:
      # * END_STREAM (0x1): When set, bit 0 indicates that the header block (Section 4.3) is the last that the endpoint will send for the identified stream.
      #   * A HEADERS frame carries the END_STREAM flag that signals the end of a stream. However, a HEADERS frame with the END_STREAM flag set can be followed by CONTINUATION frames on the same stream. Logically, the CONTINUATION frames are part of the HEADERS frame.
      # * END_HEADERS (0x4): When set, bit 2 indicates that this frame contains an entire header block (Section 4.3) and is not followed by any CONTINUATION frames.
      #   * A HEADERS frame without the END_HEADERS flag set MUST be followed by a CONTINUATION frame for the same stream. A receiver MUST treat the receipt of any other type of frame or a frame on a different stream as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
      # * PADDED (0x8): When set, bit 3 indicates that the Pad Length field and any padding that it describes are present.
      # * PRIORITY (0x20): When set, bit 5 indicates that the Exclusive Flag (E), Stream Dependency, and Weight fields are present; see Section 5.3.

      flags = io.read_byte || 0_u8
      end_stream = (flags & 0b00000001_u8).zero? ? false : true
      end_headers = (flags & 0b00000100_u8).zero? ? false : true
      padded = (flags & 0b00001000_u8).zero? ? false : true
      priority = (flags & 0b00100000_u8).zero? ? false : true

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

      # * Exclusive: A single-bit flag indicating that the stream dependency is exclusive (see Section 5.3).
      #   * This field is only present if the PRIORITY flag is set.
      # * Stream Dependency: A 31-bit stream identifier for the stream that this stream depends on (see Section 5.3).
      #   * This field is only present if the PRIORITY flag is set.
      # * Weight: An unsigned 8-bit integer representing a priority weight for the stream (see Section 5.3).
      #   * Add one to the value to obtain a weight between 1 and 256.
      #   * This field is only present if the PRIORITY flag is set.

      if priority
        exclusive_stream_dependency = Frame.parse_exclusive_stream_dependency io
        _exclusive, stream_dependency = exclusive_stream_dependency

        exclusive = _exclusive.zero? ? false : true
        weight = io.read_byte || 0_u8

        # * (I.e. Length - exclusiveStreamDependency (4 Bytes) & weight (1 Bytes))

        length -= 5_i32
      end

      # * The payload of a HEADERS frame contains a header block fragment (Section 4.3).
      #   * A header block that does not fit within a HEADERS frame is continued in a CONTINUATION frame (Section 6.10).

      hpack_decoder = hpack_decoder || Hpack::Decoder.new
      payload = Frame.read_bytes io, length

      # * After Fragment merge, perform Hpack decoding

      fragments = IO::Memory.new
      fragments.write payload

      # * Padding: Padding octets that contain no application semantic value. Padding octets MUST be set to zero when sending.
      #   * A receiver is not obligated to verify padding but MAY treat non-zero padding as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.

      io.skip padding_length if padding_length

      # * A HEADERS frame without the END_HEADERS flag set MUST be followed by a CONTINUATION frame for the same stream.
      #   * A receiver MUST treat the receipt of any other type of frame or a frame on a different stream as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.

      if continuation && !end_headers
        loop do
          # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

          if fragments.size > maximum_header_continuation_size
            message = String.build do |io|
              io << "Headers & Continuation length exceeds MAX_HEADER_CONTINUATION_SIZE " << (fragments.size - maximum_frame_size) << " Bytes"
            end

            raise IllegalLength.new message
          end

          continuation = Continuation.from_io io: io, hpack_decoder: hpack_decoder
          raise BadContinuation.new "Mismatch StreamIdentifier" if continuation.streamIdentifier != stream_identifier

          fragments.write continuation.fragment
          break end_headers = true if continuation.endHeaders
        end
      end

      # * After Fragment merge, perform Hpack decoding

      if continuation && !fragments.empty?
        http_headers = Headers.decode hpack_decoder, fragments.to_slice
      end

      # * Create Frame

      headers = new stream_identifier, http_headers, exclusive, stream_dependency, weight
      headers.endStream = end_stream
      headers.endHeaders = end_headers
      headers.padded = padded
      headers.priority = priority
      headers.paddingLength = padding_length

      headers
    end

    def to_http_request(body : IO? = nil) : HTTP::Request
      http_headers = httpHeaders.dup

      # * If the base header is missing, an exception is thrown

      raise IllegalRequest.new "Missing ':method' Header Key" unless http_headers.has_key? ":method"
      raise IllegalRequest.new "Missing ':authority' Header Key" unless http_headers.has_key? ":authority"
      raise IllegalRequest.new "Missing ':scheme' Header Key" unless http_headers.has_key? ":scheme"
      raise IllegalRequest.new "Missing ':path' Header Key" unless http_headers.has_key? ":path"

      method = http_headers.get(":method").first
      path = http_headers.get(":path").first

      http_headers.delete ":method"
      http_headers.delete ":path"

      # * Create Request

      HTTP::Request.new method: method, resource: path,
        headers: http_headers, body: body, version: "HTTP/2.0"
    end

    def self.write_flag(io : IO, end_stream : Bool?, end_headers : Bool?, padded : Bool?, priority : Bool?)
      end_stream = true if end_stream.nil?
      end_headers = true if end_headers.nil?

      flags = 0b00000000_u8
      flags = flags | (!!priority ? 0b00100000_i32 : 0b00000000_i32)
      flags = flags | (!!padded ? 0b00001000_i32 : 0b00000000_i32)
      flags = flags | (!!end_headers ? 0b00000100_i32 : 0b00000000_i32)
      flags = flags | (!!end_stream ? 0b00000001_i32 : 0b00000000_i32)

      io.write Bytes[flags]
    end

    def self.type
      Type::Headers
    end
  end
end
