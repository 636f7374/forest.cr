class HTTP::Server
  class Response
    def stream_identifier=(value : Int32)
      @streamIdentifier = value
    end

    def stream_identifier
      @streamIdentifier
    end

    def cell_stream=(value : Forest::Cell::Stream)
      @cellStream = value
    end

    def cell_stream
      @cellStream
    end

    def data_padding_length=(value : UInt8)
      @dataPaddingLength = value
    end

    def data_padding_length
      @dataPaddingLength ||= 0_u8
    end

    def data_padding_data=(value : Bytes)
      @dataPaddingData = value
    end

    def data_padding_data
      @dataPaddingData
    end

    def headers_padding_length=(value : UInt8)
      @headersPaddingLength = value
    end

    def headers_padding_length
      @headersPaddingLength ||= 0_u8
    end

    def headers_padding_data=(value : Bytes)
      @headersPaddingData = value
    end

    def headers_padding_data
      @headersPaddingData
    end

    def written=(value : Bool)
      @written = value
    end

    def written?
      @written ||= false
    end

    def write(slice : Bytes) : Nil
      return if slice.empty?
      self.written = true unless written?

      output.write slice
    end

    def write_http2_headers
      raise "Undefined streamIdentifier" unless _stream_identifier = stream_identifier

      _headers = headers.dup
      _headers[":status"] = status.value.to_s
      cookies.add_response_headers _headers

      frame = Forest::Frame::Headers.new _stream_identifier, _headers, nil, nil, nil

      frame.endStream = false
      frame.endStream = true if header_end_stream?

      if 0_u8 < headers_padding_length
        frame.padded = true
        frame.paddingLength = headers_padding_length
        frame.paddingData = headers_padding_data
      end

      cell_stream.try &.write frame
      @wrote_headers = true
    end

    protected def write_headers
      return write_http2_headers if "HTTP/2.0" == version

      write_http1_headers
    end

    protected def write_http1_headers
      @io << @version << ' ' << @status.code << ' ' << (@status_message || @status.description) << "\r\n"
      headers.each { |name, values| values.each { |value| @io << name << ": " << value << "\r\n" } }

      @io << "\r\n"
      @wrote_headers = true
    end

    def unbuffered_write_chunked_end_stream
      raise "Undefined streamIdentifier" unless _stream_identifier = stream_identifier
      return if header_end_stream? || headers["Content-Length"]?
      return unless closed?

      frame = Forest::Frame::Data.new _stream_identifier, Bytes.new 0_i32
      frame.endStream = true

      if 0_u8 < data_padding_length
        frame.padded = true
        frame.paddingLength = data_padding_length
        frame.paddingData = data_padding_data
      end

      cell_stream.try &.write frame
    end

    private def header_end_stream?
      # * If Compress is enabled, even if no data is written, it will generate some Compress packet format write

      return false if headers["Content-Encoding"]?
      written? ? false : true
    end

    def end_stream?(written_size : Int64) : Bool
      content_length = headers["Content-Length"]?.try &.to_i64 || 0_i64
      return true if content_length == written_size unless content_length.zero?

      false
    end

    def upgrade
      return if "HTTP/2.0" == version

      @upgraded = true
      write_headers
      flush

      yield @io
    end

    class Output < IO
      def written_size=(value : Int64)
        @writtenSize = value
      end

      def written_size
        @writtenSize ||= 0_i64
      end

      private def unbuffered_write(slice : Bytes)
        return unbuffered_http2_write slice if "HTTP/2.0" == response.version

        unbuffered_http1_write slice
      end

      private def unbuffered_http2_write(slice : Bytes) : Nil
        raise "Undefined cellStream" unless cell_stream = response.cell_stream
        return if slice.empty?

        ensure_headers_written
        slice_memory = IO::Memory.new slice

        loop do
          malloc_size = cell_stream.writer.flowControl.frame_size

          if 0_u8 < response.data_padding_length
            malloc_size -= 1_i32
            malloc_size -= response.data_padding_length
          end

          if slice_memory.size <= malloc_size
            length = slice_memory.size

            self.written_size += length

            break write_data slice_memory.to_slice
          else
            pointer = GC.malloc_atomic(malloc_size).as UInt8*
            length = slice_memory.read pointer.to_slice(malloc_size)
            break if length.zero?

            self.written_size += length

            write_data pointer.to_slice(length)
            break if response.end_stream? written_size
          end
        end
      end

      private def unbuffered_http1_write(slice : Bytes)
        return if slice.empty?

        unless response.wrote_headers?
          if response.version != "HTTP/1.0" && !response.headers.has_key?("Content-Length")
            response.headers["Transfer-Encoding"] = "chunked"
            @chunked = true
          end
        end

        ensure_headers_written
        return @io.write slice unless @chunked

        slice.size.to_s 16_i32, @io
        @io << "\r\n"
        @io.write slice
        @io << "\r\n"
      end

      private def write_data(slice : Bytes)
        raise "Undefined cellStream" unless cell_stream = response.cell_stream
        raise "Undefined streamIdentifier" unless _stream_identifier = response.stream_identifier

        frame = Forest::Frame::Data.new _stream_identifier, slice

        if 0_u8 < response.data_padding_length
          frame.padded = true
          frame.paddingLength = response.data_padding_length
          frame.paddingData = response.data_padding_data
        end

        frame.endStream = response.end_stream? written_size
        cell_stream.write frame
      end
    end
  end
end
