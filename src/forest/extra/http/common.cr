module HTTP
  SUPPORTED_VERSIONS_ = {"HTTP/1.0", "HTTP/1.1", "HTTP/2.0"}

  enum Version
    HTTP_1_0
    HTTP_1_1
    HTTP_2_0

    def self.from_text(version : String) : Version?
      case version
      when "HTTP/1.0"
        Version::HTTP_1_0
      when "HTTP/1.1"
        Version::HTTP_1_1
      when "HTTP/2.0"
        Version::HTTP_2_0
      else
      end
    end
  end
end
