module Forest::Cell
  class Stream < IO
    property streamIdentifier : Int32
    property reader : Reader
    property writer : Writer

    def initialize(@streamIdentifier : Int32, @reader : Reader, @writer : Writer)
      @reader.writer = writer
    end

    def write(frames : Array(Frame))
      writer.write frames
    end

    def write(frame : Frame)
      writer.write frame
    end

    def write(slice : Bytes) : Nil
    end

    def read(slice : Bytes) : Int32
      reader.window_size_increment streamIdentifier

      reader.read slice
    end

    def receive : Frame
      reader.receive
    end
  end
end
