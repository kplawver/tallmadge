# frozen_string_literal: true

module Tallmadge
  # Loads and saves ~/.tallmadge/state.json. Writes are atomic: write a
  # pid-suffixed temp file next to the target, then File.rename.
  class State
    EMPTY_PROFILE = {
      "plugins" => {},
      "marketplaces" => [],
      "userContent" => { "agentsMd" => nil, "mcpJson" => nil },
      "mcpOrigins" => {},
      "composed" => { "agentsMd" => false, "mcpJson" => false },
      "harnesses" => {}
    }.freeze

    DEFAULT = {
      "version" => 2,
      "activeProfile" => "default",
      "plugins" => {},
      "marketplaces" => {},
      "profiles" => { "default" => EMPTY_PROFILE }
    }.freeze

    attr_accessor :data

    def self.empty_profile
      deep_dup(EMPTY_PROFILE)
    end

    def self.load
      path = Paths.state_file
      migrated = false
      data = if File.exist?(path)
               raw = JSON.parse(File.read(path))
               if raw["version"] == 1 || !raw.key?("profiles")
                 migrated = true
                 migrate_v1_to_v2(raw)
               else
                 raw
               end
             else
               deep_dup(DEFAULT)
             end

      state = new(data)
      state.save if migrated
      state
    rescue JSON::ParserError => e
      raise Error, "state file #{path} is corrupt: #{e.message}"
    end

    def self.migrate_v1_to_v2(v1_data)
      v1_plugins = v1_data["plugins"] || {}
      profile_plugins = {}
      v1_plugins.each do |id, entry|
        profile_plugins[id] = { "components" => deep_dup(entry["components"] || {}) }
      end

      v1_marketplaces = v1_data["marketplaces"] || {}
      profile_marketplaces = v1_marketplaces.keys

      default_profile = {
        "plugins" => profile_plugins,
        "marketplaces" => profile_marketplaces,
        "userContent" => deep_dup(v1_data["userContent"] || { "agentsMd" => nil, "mcpJson" => nil }),
        "mcpOrigins" => deep_dup(v1_data["mcpOrigins"] || {}),
        "composed" => deep_dup(v1_data["composed"] || { "agentsMd" => false, "mcpJson" => false }),
        "harnesses" => deep_dup(v1_data["harnesses"] || {})
      }

      {
        "version" => 2,
        "activeProfile" => "default",
        "plugins" => deep_dup(v1_plugins),
        "marketplaces" => deep_dup(v1_marketplaces),
        "profiles" => {
          "default" => default_profile
        }
      }
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

    def plugins = @data["plugins"]
    def marketplaces = @data["marketplaces"]
    def plugin(id) = @data["plugins"][id]

    def profiles = @data["profiles"]
    def active_profile_name = @data["activeProfile"]
    def active_profile = @data["profiles"][active_profile_name]
    def profile_plugins = active_profile["plugins"]
    def profile_marketplaces = active_profile["marketplaces"]

    def harnesses = active_profile["harnesses"]
    def mcp_origins = active_profile["mcpOrigins"]
    def user_content = active_profile["userContent"]
    def composed = active_profile["composed"]

    def set_mcp_origins(origins)
      active_profile["mcpOrigins"] = origins
    end

    def ensure_profile_plugin!(id)
      return profile_plugins[id] if profile_plugins[id]

      global_entry = plugins[id]
      return nil unless global_entry

      components = self.class.deep_dup(global_entry["components"] || {})
      components.each do |section, items|
        case items
        when Hash
          if section == "agentsMd"
            items["active"] = false
          else
            items.each_value do |info|
              info["active"] = false if info.is_a?(Hash)
            end
          end
        end
      end

      profile_plugins[id] = { "components" => components }
    end

    def self.deep_dup(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
      when Array then obj.map { |v| deep_dup(v) }
      else obj
      end
    end
  end
end
