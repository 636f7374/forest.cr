# Commits on May 11, 2020

class HTTP::Server::RequestProcessor
  def max_header_continuation_size=(value : Int32)
    @maxHeaderContinuationSize = value
  end

  def max_header_continuation_size
    @maxHeaderContinuationSize ||= Forest::MAX_HEADER_CONTINUATION_SIZE
  end

  def max_header_table_size=(value : Int32)
    @maxHeaderTableSize = value
  end

  def max_header_table_size
    @maxHeaderTableSize ||= Forest::SETTINGS_HEADER_TABLE_SIZE
  end

  def max_concurrent_streams=(value : Int32)
    @maxConcurrentStreams = value
  end

  def max_concurrent_streams
    @maxConcurrentStreams ||= Forest::SETTINGS_MAX_CONCURRENT_STREAMS
  end

  def max_initial_window_size=(value : Int32)
    @maxInitialWindowSize = value
  end

  def max_initial_window_size
    @maxInitialWindowSize ||= Forest::SETTINGS_INITIAL_WINDOW_SIZE
  end

  def max_frame_size=(value : Int32)
    @maxFrameSize = value
  end

  def max_frame_size
    @maxFrameSize ||= Forest::SETTINGS_MAX_FRAME_SIZE
  end

  def max_header_list_size=(value : Int32)
    @maxHeaderListSize = value
  end

  def max_header_list_size
    @maxHeaderListSize ||= Forest::SETTINGS_MAX_HEADER_LIST_SIZE
  end

  private def connection_process(input : IO, output : IO, error = STDERR)
    request = HTTP::Request.from_io input, max_request_line_size: max_request_line_size,
      max_headers_size: max_headers_size rescue nil

    unless request.is_a? HTTP::Request
      input.close rescue nil

      return
    end

    unless version = Version.from_text request.version
      input.close rescue nil

      return
    end

    case version
    when Version::HTTP_1_0, Version::HTTP_1_1
      process_http1 request: request, input: input, output: output
    when Version::HTTP_2_0
      preface_buffer = uninitialized UInt8[6_i32]
      length = input.read preface_buffer.to_slice

      if preface_buffer.to_slice != Forest::CONNECTION_PREFACE_END_BYTES
        raise "Invalid HTTP2 connection Preface"
      end

      flow_control = Forest::FlowControl.new
      flow_control.max_header_continuation_size = max_header_continuation_size
      flow_control.max_header_table_size = max_header_table_size
      flow_control.max_concurrent_streams = max_concurrent_streams
      flow_control.max_initial_window_size = max_initial_window_size
      flow_control.max_frame_size = max_frame_size
      flow_control.max_header_list_size = max_header_list_size
      entry = Forest::Entry.new wrapped: input, flowControl: flow_control

      process_http2 entry: entry
    end
  end

  def process_http2_pool(entry : Forest::Entry, frame : Forest::Frame)
    spawn do
      next unless channel = entry.connectionPool[frame.streamIdentifier]?

      # * If Connection exists, send data, then next

      begin
        channel.send frame
      rescue ex
        channel.close rescue nil
        entry.connectionPool.delete frame.streamIdentifier
      end
    end
  end

  def process_http2_connection(entry : Forest::Entry, frame : Forest::Frame)
    spawn do
      _frame = frame

      # * If streamIdentifier is zero, the default call flowControl

      next unless _frame.streamIdentifier.zero?
      next unless channel = entry.connectionPool[_frame.streamIdentifier]?

      # * Create Cell Stream

      cell_reader = Forest::Cell::Reader.new io: channel, flowControl: entry.flowControl
      cell_stream = Forest::Cell::Stream.new streamIdentifier: _frame.streamIdentifier,
        reader: cell_reader, writer: entry.cellWriter

      # * If an exception occurs, write to RstStream

      begin
        entry.flowControl.call _frame, cell_stream
      rescue ex
        rst_stream = Forest::Frame::RstStream.new _frame.streamIdentifier, Forest::Frame::Error::ProtocolError
        entry.cellWriter.write rst_stream rescue nil

        entry.finished = true
      end

      channel.close rescue nil
      entry.connectionPool.delete _frame.streamIdentifier
    end
  end

  def process_http2_stream(entry : Forest::Entry, frame : Forest::Frame::Headers)
    spawn do
      _frame = frame

      # * If streamIdentifier is zero, the default call flowControl

      next if _frame.streamIdentifier.zero?
      next unless channel = entry.connectionPool[_frame.streamIdentifier]?

      # * The client and server must establish a connection before they can process the stream
      # * If socket finished, then break

      loop do
        break if entry.finished?
        next sleep 0.05_f32 unless entry.flowControl.configured?

        break
      end

      # * If socket finished, then next

      if entry.finished?
        channel.close rescue nil
        entry.connectionPool.delete _frame.streamIdentifier

        next
      end

      # * Create Cell Stream

      cell_reader = Forest::Cell::Reader.new io: channel, flowControl: entry.flowControl
      cell_stream = Forest::Cell::Stream.new streamIdentifier: _frame.streamIdentifier,
        reader: cell_reader, writer: entry.cellWriter

      # * If Headers Frame is endStream, close Reader

      cell_reader.close if frame.endStream

      # * Call handler, just like HTTP::Server::RequestProcessor

      request = _frame.to_http_request cell_stream

      response = Server::Response.new io: cell_stream, version: "HTTP/2.0"
      response.cell_stream = cell_stream
      response.stream_identifier = _frame.streamIdentifier

      context = Server::Context.new request, response
      @handler.call context rescue nil

      # * If the client is uploading data and the Handler does not handle the upload correctly,
      #   * you need to skip it, otherwise it will cause the connection to hang until timeout
      # * Since Server::Response::Output is IO::Buffered, So need to flush
      # * In order to prevent the Handler from handling the client correctly,
      #   * finally set endStream = true

      context.request.body.try &.skip_to_end rescue nil
      context.response.close rescue nil
      context.response.unbuffered_write_chunked_end_stream rescue nil

      # * After the session ends, close the channel and remove it from ConnectionPool

      channel.close rescue nil
      entry.connectionPool.delete _frame.streamIdentifier
    end
  end

  def process_http2(entry : Forest::Entry)
    loop do
      frame = Forest::Frame.from_io io: entry.wrapped, continuation: true, hpack_decoder: entry.flowControl.hpackDecoder,
        maximum_frame_size: entry.flowControl.frame_size,
        maximum_header_continuation_size: entry.flowControl.header_continuation_size rescue nil

      # * If the Frame is empty, or socket finished, close the Channel
      # * Also close socket (wrapped)

      if frame.nil? || entry.finished?
        entry.connectionPool.each { |stream_identifier, channel| channel.close rescue nil }
        entry.cellWriter.write Forest::Frame::GoAway.new 0_i32, 0_i32 rescue nil if entry.finished?

        entry.finished = true unless entry.finished?
        entry.flowControl.finished = true unless entry.flowControl.finished?
        entry.wrapped.close rescue nil

        break
      end

      # * If it exists in the ConnectionPool, send Frame through the channel

      next unless _frame = frame
      next process_http2_pool entry, _frame if entry.connectionPool[_frame.streamIdentifier]?

      # * If the ConnectionPool is full (more than the maximum number of concurrent), write to RstStream Frame, then next

      if entry.connectionPool.concurrent_full?
        rst_stream = Forest::Frame::RstStream.new _frame.streamIdentifier, Forest::Frame::Error::InternalError
        entry.cellWriter.write rst_stream rescue nil

        next
      end

      # * If everything is normal, add Channel to ConnectionPool

      channel = Channel(Forest::Frame).new
      entry.connectionPool.add _frame.streamIdentifier, channel

      # * Call connection or stream handler

      if _frame.streamIdentifier.zero?
        # * The first frame of streamIdentifier must be the Settings frame, otherwise the connection is terminated

        unless _frame.is_a? Forest::Frame::Settings
          rst_stream = Forest::Frame::RstStream.new _frame.streamIdentifier, Forest::Frame::Error::ProtocolError
          entry.cellWriter.write rst_stream rescue nil

          next entry.finished = true
        end

        process_http2_connection entry, _frame
      else
        # * If the first frame of the stream is not headers, write to RstStream Frame, then next

        unless _frame.is_a? Forest::Frame::Headers
          rst_stream = Forest::Frame::RstStream.new _frame.streamIdentifier, Forest::Frame::Error::ProtocolError
          entry.cellWriter.write rst_stream rescue nil

          next entry.finished = true
        end

        process_http2_stream entry, _frame
      end
    end
  end

  def process_http1(request : HTTP::Request, input : IO, output : IO)
    response = Response.new output
    first_process = true

    begin
      until @wants_close
        if first_process
          first_process = false
        else
          request = HTTP::Request.from_io(input, max_request_line_size: max_request_line_size, max_headers_size: max_headers_size)
        end

        # EOF

        break unless request

        if request.is_a? HTTP::Status
          response.respond_with_status request

          return
        end

        response.version = request.version
        response.reset
        response.headers["Connection"] = "keep-alive" if request.keep_alive?
        context = Context.new request, response

        begin
          @handler.call context
        rescue ex : ClientError
          Log.debug(exception: ex.cause) { ex.message }
        rescue ex
          Log.error(exception: ex) { "Unhandled exception on HTTP::Handler" }

          unless response.closed?
            unless response.wrote_headers?
              response.respond_with_status :internal_server_error
            end
          end

          return
        ensure
          response.output.close
        end

        output.flush

        # If there is an upgrade handler, hand over
        # the connection to it and return

        if upgrade_handler = response.upgrade_handler
          upgrade_handler.call output

          return
        end

        break unless request.keep_alive?

        # Don't continue if the handler set `Connection` header to `close`

        break unless HTTP.keep_alive? response

        # The request body is either FixedLengthContent or ChunkedContent.
        # In case it has not entirely been consumed by the handler, the connection is
        # closed the connection even if keep alive was requested.

        case body = request.body
        when FixedLengthContent
          if body.read_remaining > 0_i32
            # Close the connection if there are bytes remaining

            break
          end
        when ChunkedContent
          # Close the connection if the IO has still bytes to read.

          break unless body.closed?
        else
          # Nothing to do
        end
      end
    rescue IO::Error
      # IO-related error, nothing to do
    end
  end

  def process(input : IO, output : IO, error = STDERR)
    connection_process input: input, output: output, error: error
  end
end
