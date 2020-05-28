class Forest::Frame
  class PushPromise < Frame
    property streamIdentifier : Int32
    property promisedStreamId : Int32
    property httpHeaders : HTTP::Headers
    property endHeaders : Bool?
    property padded : Bool?
    property paddingLength : UInt8?
    property paddingData : Bytes?

    def initialize(@streamIdentifier : Int32, httpHeaders : HTTP::Headers?, @promisedStreamId : Int32)
      @httpHeaders = httpHeaders || HTTP::Headers.new
      @endHeaders = nil
      @padded = nil
      @paddingLength = nil
    end

    def encode(hpack_encoder : Hpack::Encoder, headers : HTTP::Headers? = self.httpHeaders)
      hpack_encoder.encode headers: headers || HTTP::Headers.new
    end

    def self.decode(hpack_decoder : Hpack::Decoder, payload : Bytes)
      hpack_decoder.decode bytes: payload.to_slice
    end

    def to_io(io : IO, padding_data : Bytes? = self.paddingData)
      padding_length = paddingLength
      length = 5_i32

      if padded && padding_length
        length += 1_i32
        length += padding_length
      end

      Frame.write_length_type io, length, PushPromise.type
      PushPromise.write_flag io, endHeaders, padded
      Frame.write_stream_identifier io, streamIdentifier
      Frame.write_promised_stream_id io, promisedStreamId

      if padded && padding_length
        io.write Bytes[padding_length]
      end

      if padded && padding_length
        Frame.write_padding io, padding_length, padding_data
      end
    end

    def to_io(io : IO, hpack_encoder : Hpack::Encoder? = nil, padding_data : Bytes? = self.paddingData, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE)
      if httpHeaders.empty?
        self.endHeaders = true
        to_io io, padding_data

        return
      end

      self.endHeaders = false
      to_io io, padding_data

      payload = PushPromise.encode hpack_encoder, httpHeaders
      remaining_memory = IO::Memory.new payload
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

    def self.from_io(io : IO, continuation : Bool, hpack_decoder : Hpack::Decoder? = nil, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE, maximum_header_continuation_size : Int32 = MAX_HEADER_CONTINUATION_SIZE) : PushPromise
      length, _type = Frame.parse_length_type io
      raise MismatchFrame.new "Mismatch Type" if PushPromise.type != Type.new _type.to_u8

      from_io io, length, continuation, hpack_decoder, maximum_frame_size, maximum_header_continuation_size
    end

    def self.from_io(io : IO, length : Int32, continuation : Bool, hpack_decoder : Hpack::Decoder? = nil, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE, maximum_header_continuation_size : Int32 = MAX_HEADER_CONTINUATION_SIZE) : PushPromise
      # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

      if length > maximum_frame_size
        message = String.build do |io|
          io << "Frame length exceeds SETTINGS_MAX_FRAME_SIZE " << (length - maximum_frame_size) << " Bytes"
        end

        raise IllegalLength.new message
      end

      # * The PUSH_PROMISE frame defines the following flags:
      # * END_HEADERS (0x4): When set, bit 2 indicates that this frame contains an entire header block (Section 4.3) and is not followed by any CONTINUATION frames.
      #   * A PUSH_PROMISE frame without the END_HEADERS flag set MUST be followed by a CONTINUATION frame for the same stream.
      #   * A receiver MUST treat the receipt of any other type of frame or a frame on a different stream as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
      # * PADDED (0x8): When set, bit 3 indicates that the Pad Length field and any padding that it describes are present.

      flags = io.read_byte || 0_u8
      end_headers = (flags & 0b00000100_u8).zero? ? false : true
      padded = (flags & 0b00001000_u8).zero? ? false : true

      # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.
      # * Stream Identifier: A stream identifier (see Section 5.1.1) expressed as an unsigned 31-bit integer.
      #   * The value 0x0 is reserved for frames that are associated with the connection as a whole as opposed to an individual stream.

      stream_identifier = Frame.parse_stream_identifier io

      # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.
      # * Promised Stream ID: An unsigned 31-bit integer that identifies the stream that is reserved by the PUSH_PROMISE. The promised stream identifier MUST be a valid choice for the next stream sent by the sender (see "new stream identifier" in Section 5.1.1).

      promised_stream_id = Frame.parse_promised_stream_id io

      # * Padding Length: An 8-bit field containing the length of the frame padding in units of octets.
      #   * This field is only present if the PADDED flag is set.

      if padded
        padding_length = io.read_byte

        # * (I.e. Padding Length (1 Bytes))
        length -= 1_i32
      end

      # * (I.e. Length - promisedStreamId (4 Bytes))

      length -= 4_i32

      # * After Fragment merge, perform Hpack decoding

      fragments = IO::Memory.new

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
        http_headers = PushPromise.decode hpack_decoder, fragments.to_slice
      end

      # * Create Frame

      push_promise = new stream_identifier, http_headers, promised_stream_id
      push_promise.endHeaders = end_headers
      push_promise.padded = padded
      push_promise.paddingLength = padding_length

      push_promise
    end

    def self.write_flag(io : IO, end_headers : Bool?, padded : Bool?)
      end_headers = true if end_headers.nil?

      flags = 0b00000000_i32
      flags = flags | (!!padded ? 0b00001000_i32 : 0b00000000_i32)
      flags = flags | (!!end_headers ? 0b00000100_i32 : 0b00000000_i32)

      io.write Bytes[flags]
    end

    def self.type
      Type::PushPromise
    end
  end
end
