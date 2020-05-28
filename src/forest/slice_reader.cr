class SliceReader
  property offset : Int32
  property slice : Bytes
  property defaultEndianness : IO::ByteFormat

  def initialize(@slice : Bytes, @defaultEndianness = IO::ByteFormat::SystemEndian)
    @offset = 0_i32
  end

  def done?
    slice.size <= offset
  end

  def current_byte
    slice[offset]
  end

  def read_byte
    current_byte.tap { self.offset += 1_i32 }
  end

  {% for type, i in %w(UInt8 Int8 UInt16 Int16 UInt32 Int32 UInt64 Int64) %}
  def read_bytes(type : {{type.id}}.class, endianness : IO::ByteFormat = self.default_endianness)
    {% size = 2_i32 ** (i // 2_i32) %}

    buffer = slice[offset, {{size}}]
    self.offset += {{size}}

    {% if size > 1_i32 %}
      buffer.reverse! unless endianness == IO::ByteFormat::SystemEndian
    {% end %}

    buffer.unsafe_as {{type.id}}
  end
  {% end %}

  def read(count : Int)
    count = slice.size - offset - count if 0_i32 > count
    slice[offset, count].tap { self.offset += count }
  end
end
