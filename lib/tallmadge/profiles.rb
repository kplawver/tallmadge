# frozen_string_literal: true

module Tallmadge
  # Profile management: named selections over the shared plugin installation store.
  module Profiles
    NAME_RE = Marketplace::NAME_RE

    module_function

    def validate_name!(name)
      return if name.is_a?(String) && name.match?(NAME_RE) && name.length <= 64

      raise Error, "invalid profile name #{name.inspect} (must match #{NAME_RE.source}, max 64 chars)"
    end

    def create(state, name)
      validate_name!(name)
      raise Error, "profile '#{name}' already exists" if state.profiles.key?(name)

      state.profiles[name] = State.empty_profile
      state.save
      Reporter.ok "created profile #{Reporter.name(name)}"
    end

    def remove(state, name)
      unless state.profiles.key?(name)
        known = state.profiles.keys.sort.join(", ")
        raise Error, "unknown profile '#{name}' (profiles: #{known})"
      end

      if name == state.active_profile_name
        raise Error, "profile '#{name}' is active; activate another profile first"
      end

      state.profiles.delete(name)
      FileUtils.rm_rf(Paths.profile_dir(name))
      state.save
      Reporter.ok "removed profile #{name}"
    end

    def switch(state, name)
      unless state.profiles.key?(name)
        known = state.profiles.keys.sort.join(", ")
        raise Error, "unknown profile '#{name}' (profiles: #{known})"
      end

      if name == state.active_profile_name
        Reporter.info "profile '#{name}' is already active"
        return
      end

      Activator.new(state).teardown_profile!
      state.data["activeProfile"] = name
      Activator.new(state).apply_profile!
      state.save
      Reporter.ok "switched to profile #{Reporter.name(name)}"
    end

    def list(state)
      rows = state.profiles.keys.sort.map do |name|
        prof = state.profiles[name]
        mark = name == state.active_profile_name ? "* " : ""

        active_components = 0
        (prof["plugins"] || {}).each_value do |p_entry|
          components = p_entry["components"] || {}
          components.each do |section, items|
            case items
            when Hash
              if section == "agentsMd"
                active_components += 1 if items["active"]
              else
                items.each_value do |info|
                  active_components += 1 if info.is_a?(Hash) && info["active"]
                end
              end
            end
          end
        end

        plugin_count = (prof["plugins"] || {}).size
        [
          "#{mark}#{name}",
          "#{plugin_count} #{plugin_count == 1 ? 'plugin' : 'plugins'}",
          "#{active_components} active"
        ]
      end

      Reporter.table(rows, %w[profile plugins active])
    end
  end

  # Thor subcommand: clpr profile ...
  class ProfileCLI < Thor
    class_option :no_color, type: :boolean, default: false

    desc "create NAME", "Create a new empty profile"
    def create(name)
      Profiles.create(State.load, name)
    end

    desc "activate NAME", "Switch to a profile (updates ~/.agents links and composed files)"
    map %w[use switch] => :activate
    def activate(name)
      Profiles.switch(State.load, name)
    end

    desc "list", "List profiles"
    def list
      Profiles.list(State.load)
    end

    desc "current", "Print the active profile name"
    def current
      puts State.load.active_profile_name
    end

    desc "remove NAME", "Remove a profile (cannot be the active one)"
    def remove(name)
      Profiles.remove(State.load, name)
    end
  end
end
