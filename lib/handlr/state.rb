# frozen_string_literal: true

module Handlr
  # Loads and saves ~/.handlr/state.json. Writes are atomic: write a
  # pid-suffixed temp file next to the target, then File.rename.
  class State
    DEFAULT = {
      "version" => 1,
      "marketplaces" => {},
      "plugins" => {},
      "harnesses" => {},
      "mcpOrigins" => {},
      "userContent" => { "agentsMd" => nil, "mcpJson" => nil },
      "composed" => { "agentsMd" => false, "mcpJson" => false }
    }.freeze

    attr_accessor :data

    def self.load
      path = Paths.state_file
      data = File.exist?(path) ? JSON.parse(File.read(path)) : deep_dup(DEFAULT)
      new(data)
    rescue JSON::ParserError => e
      raise Error, "state file #{path} is corrupt: #{e.message}"
    end

    def initialize(data)
      @data = data
    end

    def save
      path = Paths.state_file
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}"
      File.write(tmp, JSON.pretty_generate(@data) + "\n")
      File.rename(tmp, path)
      self
    end

    def marketplaces = @data["marketplaces"]
    def plugins = @data["plugins"]
    def harnesses = @data["harnesses"]
    def mcp_origins = @data["mcpOrigins"]
    def user_content = @data["userContent"]
    def composed = @data["composed"]

    def plugin(id) = @data["plugins"][id]

    def self.deep_dup(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
      when Array then obj.map { |v| deep_dup(v) }
      else obj
      end
    end
  end
end
