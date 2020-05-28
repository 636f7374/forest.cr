module Forest
  class UnexpectedFrame < Exception
  end

  class IllegalLength < Exception
  end

  class MismatchFrame < Exception
  end

  class MalformedPacket < Exception
  end

  class BadContinuation < Exception
  end

  class IllegalRequest < Exception
  end

  MAX_HEADER_CONTINUATION_SIZE    = 65536_i32
  CONNECTION_PREFACE_END_BYTES    = Bytes[83_i32, 77_i32, 13_i32, 10_i32, 13_i32, 10_i32]
  SETTINGS_HEADER_TABLE_SIZE      =  4096_i32
  SETTINGS_ENABLE_PUSH            =     0_i32
  SETTINGS_MAX_CONCURRENT_STREAMS =   100_i32
  SETTINGS_INITIAL_WINDOW_SIZE    = 65535_i32
  SETTINGS_MAX_FRAME_SIZE         = 16384_i32
  SETTINGS_MAX_HEADER_LIST_SIZE   =  4096_i32
end
