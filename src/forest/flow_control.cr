class Forest::FlowControl
  property hpackEncoder : Hpack::Encoder
  property hpackDecoder : Hpack::Decoder
  property configured : Bool
  property finished : Bool
  property inboundWindowRemaining : Atomic(Int32)
  property outboundWindowRemaining : Atomic(Int32)

  def initialize(@hpackEncoder : Hpack::Encoder = Hpack::Encoder.new, @hpackDecoder : Hpack::Decoder = Hpack::Decoder.new)
    @configured = false
    @finished = false
    @inboundWindowRemaining = Atomic(Int32).new 0_i32
    @outboundWindowRemaining = Atomic(Int32).new 0_i32
  end

  def max_header_continuation_size=(value : Int32)
    @maxHeaderContinuationSize = value
  end

  def max_header_continuation_size
    @maxHeaderContinuationSize ||= MAX_HEADER_CONTINUATION_SIZE
  end

  def max_header_table_size=(value : Int32)
    @maxHeaderTableSize = value
  end

  def max_header_table_size
    @maxHeaderTableSize ||= SETTINGS_HEADER_TABLE_SIZE
  end

  def max_concurrent_streams=(value : Int32)
    @maxConcurrentStreams = value
  end

  def max_concurrent_streams
    @maxConcurrentStreams ||= SETTINGS_MAX_CONCURRENT_STREAMS
  end

  def max_initial_window_size=(value : Int32)
    @maxInitialWindowSize = value
  end

  def max_initial_window_size
    @maxInitialWindowSize ||= SETTINGS_INITIAL_WINDOW_SIZE
  end

  def max_frame_size=(value : Int32)
    @maxFrameSize = value
  end

  def max_frame_size
    @maxFrameSize ||= SETTINGS_MAX_FRAME_SIZE
  end

  def max_header_list_size=(value : Int32)
    @maxHeaderListSize = value
  end

  def max_header_list_size
    @maxHeaderListSize ||= SETTINGS_MAX_HEADER_LIST_SIZE
  end

  def header_continuation_size=(value : Int32)
    @headerContinuationSize = value
  end

  def header_continuation_size
    @headerContinuationSize || max_header_continuation_size
  end

  def header_table_size=(value : Int32)
    return if (0_i32 > value) || (value < max_header_table_size)

    hpackDecoder.dynamicTable.resize value
    @headerTableSize = value
  end

  def header_table_size
    @headerTableSize || max_header_table_size
  end

  def enable_push=(value : Int32)
    raise Exception.new "Illegal enablePush value" unless (0_i32..1_i32).includes? value

    @enablePush = value
  end

  def enable_push
    @enablePush ||= SETTINGS_ENABLE_PUSH
  end

  def concurrent_streams=(value : Int32)
    return if (0_i32 > value) || (value < max_concurrent_streams)

    @concurrentStreams = value
  end

  def concurrent_streams
    @concurrentStreams || max_concurrent_streams
  end

  def initial_window_size=(value : Int32)
    return if (0_i32 > value) || (value < max_initial_window_size)

    @initialWindowSize = value
  end

  def initial_window_size
    @initialWindowSize || max_initial_window_size
  end

  def frame_size=(value : Int32)
    return if (0_i32 > value) || (value < max_frame_size)

    @frameSize = value
  end

  def frame_size
    @frameSize || max_frame_size
  end

  def header_list_size=(value : Int32)
    return if (0_i32 > value) || (value < max_header_list_size)

    @headerListSize = value
  end

  def header_list_size
    @headerListSize || max_header_list_size
  end

  def configured?
    @configured
  end

  def finished?
    @finished
  end

  def unpack_frame(frame : Frame::Settings)
    return unless _settings = frame.settings

    _settings.each do |parameter, value|
      case parameter
      when .header_table_size?
        self.header_table_size = value
      when .enable_push?
        self.enable_push = value
      when .max_concurrent_streams?
        self.max_concurrent_streams = value
      when .initial_window_size?
        self.initial_window_size = value
      when .max_frame_size?
        self.max_frame_size = value
      when .max_header_list_size?
        self.max_header_list_size = value
      end
    end
  end

  def exchange_settings(frame : Frame::Settings, cell_stream : Cell::Stream)
    unpack_frame frame

    settings = [] of Tuple(Frame::Settings::Parameter, Int32)
    settings << Tuple.new Frame::Settings::Parameter::HeaderTableSize, header_table_size
    settings << Tuple.new Frame::Settings::Parameter::EnablePush, enable_push
    settings << Tuple.new Frame::Settings::Parameter::MaxConcurrentStreams, max_concurrent_streams
    settings << Tuple.new Frame::Settings::Parameter::InitialWindowSize, initial_window_size
    settings << Tuple.new Frame::Settings::Parameter::MaxFrameSize, max_frame_size
    settings << Tuple.new Frame::Settings::Parameter::MaxHeaderListSize, max_header_list_size

    frame = Frame::Settings.new 0_i32, settings
    frame.ack = false
    cell_stream.write frame
  end

  def exchange(initial_frame : Frame::Settings, cell_stream : Cell::Stream) : Bool
    exchange_settings initial_frame, cell_stream
    ack = false

    loop do
      break if finished?
      frame = cell_stream.receive

      case frame
      when Frame::WindowUpdate
        self.outboundWindowRemaining.add frame.windowSizeIncrement
      when Frame::Settings
        ack = true if frame.ack

        frame = Frame::Settings.new 0_i32, nil
        frame.ack = true

        break cell_stream.write frame
      else
      end
    end

    ack
  end

  def call(initial_frame : Frame::Settings, cell_stream : Cell::Stream)
    return unless ack = exchange initial_frame, cell_stream
    self.configured = true

    loop do
      break if finished?
      frame = cell_stream.receive

      case frame
      when Frame::WindowUpdate
        self.outboundWindowRemaining.add frame.windowSizeIncrement
      when Frame::Settings
        if frame.ack
          settings = Frame::Settings.new 0_i32, nil
          settings.ack = true

          cell_stream.write settings
        else
          exchange_settings frame, cell_stream
        end
      when Frame::RstStream
        raise "Received RstStream Frame"
      when Frame::GoAway
        raise "Received GoAway Frame"
      when Frame::Ping
        ping = Frame::Ping.new 0_i32
        ping.ack = true

        cell_stream.write ping
      else
        raise "Illegal frame received"
      end
    end
  end
end
