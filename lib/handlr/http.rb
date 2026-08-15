# frozen_string_literal: true

module Handlr
  # Minimal HTTP GET with bounded redirect following.
  module Http
    module_function

    def get(url, redirects: 3)
      uri = URI(url)
      unless %w[http https].include?(uri.scheme)
        raise Error, "unsupported URL scheme: #{url}"
      end

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.open_timeout = 15
        http.read_timeout = 60
        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = "handlr/#{VERSION}"
        response = http.request(request)

        case response
        when Net::HTTPSuccess
          response.body
        when Net::HTTPRedirection
          raise Error, "too many redirects fetching #{url}" if redirects.zero?

          location = response["location"]
          raise Error, "redirect without location from #{url}" unless location

          return get(URI.join(url, location).to_s, redirects: redirects - 1)
        else
          raise Error, "HTTP #{response.code} fetching #{url}"
        end
      end
    end
  end
end
