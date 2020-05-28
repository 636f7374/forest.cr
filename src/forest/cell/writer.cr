module Forest::Cell
  class Writer
    property io : IO
    property flowControl : FlowControl
    property mutex : Mutex
    property windowRemaining : Atomic(Int32)

    def initialize(@io : IO, @flowControl : FlowControl)
      @mutex = Mutex.new :unchecked
      @windowRemaining = Atomic(Int32).new flowControl.initial_window_size
    end

    private def write_window_size_increment(stream_identifier : Int32, increment : Int32)
      window_update = Frame::WindowUpdate.new stream_identifier, increment
      window_update.to_io io: io
    end

    def set_window_size_increment(stream_identifier : Int32, increment : Int32)
      window_update = Frame::WindowUpdate.new stream_identifier, increment
      write window_update
    end

    private def window_size_increment(data_length : Int32, stream_identifier : Int32)
      flow_control_outbound_window_remaining = flowControl.outboundWindowRemaining.get
      window_remaining = windowRemaining.get

      if data_length > flow_control_outbound_window_remaining
        increment = flowControl.initial_window_size
        increment += (0_i32 - flow_control_outbound_window_remaining) if 0_i32 > flow_control_outbound_window_remaining

        write_window_size_increment 0_i32, increment
        flowControl.outboundWindowRemaining.add increment
      end

      if data_length > window_remaining
        increment = flowControl.initial_window_size
        increment += (0_i32 - window_remaining) if 0_i32 > window_remaining

        write_window_size_increment stream_identifier, increment
        self.windowRemaining.add increment
      end
    end

    def read(slice : Bytes) : Int32
      raise "Can't read from Forest::Cell::Writer"
    end

    def flush
      @io.flush
    end

    def rewind
      raise "Can't rewind from Forest::Cell::Writer"
    end

    def write(frames : Array(Frame), sync_flush : Bool = true)
      @mutex.synchronize do
        frames.each do |frame|
          case frame
          when Frame::Continuation
            frame.to_io io: io, hpack_encoder: flowControl.hpackEncoder
          when Frame::Headers
            frame.to_io io: io, hpack_encoder: flowControl.hpackEncoder, maximum_frame_size: flowControl.frame_size
          when Frame::Data
            window_size_increment data_length: frame.length, stream_identifier: frame.streamIdentifier
            frame.to_io io: io

            self.windowRemaining.add -frame.length
            flowControl.outboundWindowRemaining.add -frame.length
          else
            frame.to_io io: io
          end
        end

        flush if sync_flush
      end
    end

    def write(frame : Frame)
      write [frame]
    end
  end
end
