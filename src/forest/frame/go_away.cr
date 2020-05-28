class Forest::Frame
  class GoAway < Frame
    property streamIdentifier : Int32
    property promisedStreamId : Int32
    property error : Error

    def initialize(@streamIdentifier : Int32, @promisedStreamId : Int32, @error : Error = Error::NoError)
    end

    def to_io(io : IO)
      Frame.write_length_type io, 8_i32, GoAway.type
      GoAway.write_flag io
      Frame.write_stream_identifier io, streamIdentifier
      Frame.write_promised_stream_id io, promisedStreamId
      Frame.write_error io, error
    end

    def self.from_io(io : IO, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : GoAway
      length, _type = Frame.parse_length_type io
      raise MismatchFrame.new "Mismatch Type" if GoAway.type != Type.new _type.to_u8

      from_io io, length, maximum_frame_size
    end

    def self.from_io(io : IO, length : Int32, maximum_frame_size : Int32 = SETTINGS_MAX_FRAME_SIZE) : GoAway
      # * Exceeding the rated size will throw an exception, prevent excessive memory consumption, and malicious attacks

      if length > maximum_frame_size
        message = String.build do |io|
          io << "Frame length exceeds SETTINGS_MAX_FRAME_SIZE " << (length - maximum_frame_size) << " Bytes"
        end

        raise IllegalLength.new message
      end

      # * The GOAWAY frame does not define any flags.

      unused_flag = io.skip 1_i32

      # * R: A reserved 1-bit field. The semantics of this bit are undefined, and the bit MUST remain unset (0x0) when sending and MUST be ignored when receiving.
      # * Stream Identifier: A stream identifier (see Section 5.1.1) expressed as an unsigned 31-bit integer.
      #   * The value 0x0 is reserved for frames that are associated with the connection as a whole as opposed to an individual stream.

      stream_identifier = Frame.parse_stream_identifier io

      # * The last stream identifier in the GOAWAY frame contains the highest-numbered stream identifier for which the sender of the GOAWAY frame might have taken some action on or might yet take action on.
      #   * All streams up to and including the identified stream might have been processed in some way.
      #   * The last stream identifier can be set to 0 if no streams were processed.

      promised_stream_id = Frame.parse_promised_stream_id io

      # * Error codes are 32-bit fields that are used in RST_STREAM and GOAWAY frames to convey the reasons for the stream or connection error.
      #   * Error codes share a common code space. Some error codes apply only to either streams or the entire connection and have no defined semantics in the other context.
      # * The following error codes are defined:
      # * NO_ERROR (0x0): The associated condition is not a result of an error. For example, a GOAWAY might include this code to indicate graceful shutdown of a connection.
      # * PROTOCOL_ERROR (0x1): The endpoint detected an unspecific protocol error. This error is for use when a more specific error code is not available.
      # * INTERNAL_ERROR (0x2): The endpoint encountered an unexpected internal error.
      # * FLOW_CONTROL_ERROR (0x3): The endpoint detected that its peer violated the flow-control protocol.
      # * SETTINGS_TIMEOUT (0x4): The endpoint sent a SETTINGS frame but did not receive a response in a timely manner. See Section 6.5.3 ("Settings Synchronization").
      # * STREAM_CLOSED (0x5): The endpoint received a frame after a stream was half-closed.
      # * FRAME_SIZE_ERROR (0x6): The endpoint received a frame with an invalid size.
      # * REFUSED_STREAM (0x7): The endpoint refused the stream prior to performing any application processing (see Section 8.1.4 for details).
      # * CANCEL (0x8): Used by the endpoint to indicate that the stream is no longer needed.
      # * COMPRESSION_ERROR (0x9): The endpoint is unable to maintain the header compression context for the connection.
      # * CONNECT_ERROR (0xa): The connection established in response to a CONNECT request (Section 8.3) was reset or abnormally closed.
      # * ENHANCE_YOUR_CALM (0xb): The endpoint detected that its peer is exhibiting a behavior that might be generating excessive load.
      # * INADEQUATE_SECURITY (0xc): The underlying transport has properties that do not meet minimum security requirements (see Section 9.2).
      # * HTTP_1_1_REQUIRED (0xd): The endpoint requires that HTTP/1.1 be used instead of HTTP/2.
      # * Unknown or unsupported error codes MUST NOT trigger any special behavior.
      #   * These MAY be treated by an implementation as being equivalent to INTERNAL_ERROR.

      error = Error.new io.read_bytes UInt32, IO::ByteFormat::BigEndian

      # * (I.e. Length - promisedStreamId (4 Bytes) & Error (4 Bytes))

      length -= 8_i32

      # * Create Frame

      new stream_identifier, promised_stream_id, error
    end

    def self.write_flag(io : IO)
      # * The GOAWAY frame does not define any flags.

      io.write Bytes[0_i32]
    end

    def self.type
      Type::GoAway
    end
  end
end
