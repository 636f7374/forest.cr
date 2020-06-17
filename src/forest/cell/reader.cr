module Forest::Cell
  class Reader < IO
    include IO::Buffered

    property io : Channel(Frame)
    property flowControl : FlowControl
    property windowRemaining : Atomic(Int32)
    property mutex : Mutex

    def initialize(@io : Channel(Frame), @flowControl : FlowControl)
      @buffer_size = flowControl.initial_window_size
      @windowRemaining = Atomic(Int32).new flowControl.initial_window_size
      @mutex = Mutex.new :unchecked
    end

    def writer=(value : Writer)
      @writer = value
    end

    def writer
      @writer
    end

    def zero_window_remaining?
      (0_i32 > windowRemaining.get) || windowRemaining.get.zero?
    end

    def unbuffered_write(slice : Bytes) : Int64
      raise "Can't read from Forest::Cell::Reader"
    end

    def unbuffered_flush
      raise "Can't flush from Forest::Cell::Reader"
    end

    def unbuffered_rewind
      raise "Can't rewind from Forest::Cell::Reader"
    end

    private def unbuffered_close
      @closed = true
    end

    def closed?
      @closed
    end

    def close
      return if closed?

      super
    end

    def receive : Frame
      frame = io.receive

      if frame.is_a? Frame::Data
        self.windowRemaining.add -frame.length
        flowControl.inboundWindowRemaining.add -frame.length
      end

      if frame.responds_to? :endStream
        close if frame.endStream
      end

      frame
    end

    def window_size_increment(stream_identifier : Int32)
      @mutex.synchronize do
        flow_control_inbound_window_remaining = flowControl.inboundWindowRemaining.get
        window_remaining = windowRemaining.get

        if (0_i32 > flow_control_inbound_window_remaining) || flow_control_inbound_window_remaining.zero?
          increment = flowControl.initial_window_size
          increment += (0_i32 - flow_control_inbound_window_remaining) if 0_i32 > flow_control_inbound_window_remaining

          writer.try &.set_window_size_increment 0_i32, increment
          flowControl.inboundWindowRemaining.add increment
        end

        if (0_i32 > window_remaining) || window_remaining.zero?
          increment = flowControl.initial_window_size
          increment += (0_i32 - window_remaining) if 0_i32 > window_remaining

          writer.try &.set_window_size_increment stream_identifier, increment
          self.windowRemaining.add increment
        end
      end
    end

    def unbuffered_read(slice : Bytes) : Int32
      loop do
        case frame = receive
        when Frame::Ping
          ping = Frame::Ping.new frame.streamIdentifier
          ping.ack = true

          writer.try &.write ping
        when Frame::Data
          memory = IO::Memory.new frame.payload
          break memory.read slice
        when Frame::RstStream
          raise "Received RstStream Frame"
        when Frame::GoAway
          raise "Received GoAway Frame"
        when Frame::PushPromise
          raise "Unsupported PushPromise Feature"
        when Frame::Priority
        else
          raise "Illegal frame received"
        end
      end
    end
  end
end
