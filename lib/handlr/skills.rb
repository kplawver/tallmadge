# frozen_string_literal: true

module Handlr
  # Skill-name resolution across installed plugins for the skill-level
  # commands.
  module Skills
    module_function

    # Returns the plugin id owning a skill with this name. Requires exactly
    # one owner; unknown/ambiguous names raise with candidates.
    def find_owner!(state, name)
      owners = state.plugins.each_key.select do |id|
        state.plugins[id].dig("components", "skills", name)
      end

      case owners.size
      when 0
        available = state.plugins.flat_map do |id, entry|
          (entry.dig("components", "skills") || {}).keys.map { |skill| "#{skill} (#{id})" }
        end
        msg = "no skill named '#{name}' in any installed plugin"
        msg += " — available: #{available.join(', ')}" unless available.empty?
        raise Error, msg
      when 1
        owners.first
      else
        raise Error, "skill '#{name}' exists in multiple plugins: #{owners.join(', ')}; " \
                     "activate it via `handlr activate <plugin> --skill #{name}`"
      end
    end

    # Flat [name, plugin, active] rows across every plugin.
    def all_rows(state)
      rows = []
      state.plugins.each do |id, entry|
        (entry.dig("components", "skills") || {}).each do |name, info|
          rows << [name, id, info["active"]]
        end
      end
      rows.sort_by { |row| [row[0], row[1]] }
    end
  end

  # Thor subcommand: handlr skill ...
  class SkillCLI < Thor
    class_option :no_color, type: :boolean, default: false

    desc "activate NAME", "Activate a single skill by name"
    option :force, type: :boolean, desc: "Back up and replace conflicting targets"
    def activate(name)
      state = State.load
      Paths.ensure_skeleton!
      plugin_id = Skills.find_owner!(state, name)
      Activator.new(state).activate(plugin_id, only: [["skills", name]], force: options[:force])
    end

    desc "deactivate NAME", "Deactivate a single skill by name"
    def deactivate(name)
      state = State.load
      plugin_id = Skills.find_owner!(state, name)
      Activator.new(state).deactivate(plugin_id, only: [["skills", name]])
    end
  end
end
