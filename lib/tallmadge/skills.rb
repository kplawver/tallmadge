# frozen_string_literal: true

module Tallmadge
  # Skill-name resolution across installed plugins for the skill-level
  # commands, plus skills the user authored (kept in one managed plugin).
  module Skills
    USER_PLUGIN_ID = "user-skills"
    NAME_PATTERN = /\A[a-z0-9]+(-[a-z0-9]+)*\z/
    DEFAULT_DESCRIPTION = "Describe what this skill does and when to use it."

    module_function

    # Path to a user-authored skill's SKILL.md, or nil when there is none.
    def user_skill_file(state, name)
      return unless state.plugins.dig(USER_PLUGIN_ID, "components", "skills", name)

      File.join(Paths.plugin_dir(USER_PLUGIN_ID), "skills", name, "SKILL.md")
    end

    def user_skill_names(state)
      (state.plugins.dig(USER_PLUGIN_ID, "components", "skills") || {}).keys.sort
    end

    # Scaffolds skills/<name>/SKILL.md in the user-skills plugin, registers
    # it as a user-sourced plugin, and activates the skill. Returns SKILL.md.
    def create_user_skill!(state, name, description: nil)
      raise Error, "invalid skill name '#{name}' (use lowercase letters, digits, and hyphens)" unless name.match?(NAME_PATTERN)

      owners = owners_of(state, name)
      raise Error, "skill '#{name}' already exists in: #{owners.join(', ')}" unless owners.empty?

      path = File.join(Paths.plugin_dir(USER_PLUGIN_ID), "skills", name, "SKILL.md")
      raise Error, "#{path} already exists" if File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, skill_template(name, description || DEFAULT_DESCRIPTION))
      Installer.new(state).finish(USER_PLUGIN_ID, { "type" => "user" }, nil, report: false)
      Activator.new(state).activate(USER_PLUGIN_ID, only: [["skills", name]])
      path
    end

    # Deactivates and removes one user-authored skill from the store.
    def delete_user_skill!(state, name)
      path = user_skill_file(state, name)
      raise Error, "no skill you created is named '#{name}'#{user_skill_hint(state)}" unless path

      Activator.new(state).deactivate(USER_PLUGIN_ID, only: [["skills", name]])
      FileUtils.rm_rf(File.dirname(path))
      Installer.new(state).finish(USER_PLUGIN_ID, { "type" => "user" }, nil, report: false)
    end

    def user_skill_hint(state)
      names = user_skill_names(state)
      names.empty? ? "" : " — your skills: #{names.join(', ')}"
    end

    def skill_template(name, description)
      # JSON strings are valid YAML; Frontmatter.serialize leaves values unquoted.
      Frontmatter.serialize({ "name" => name, "description" => description.to_json },
                            "# #{name}\n\nInstructions for the agent go here.\n")
    end

    def owners_of(state, name)
      state.plugins.each_key.select { |id| state.plugins[id].dig("components", "skills", name) }
    end

    # Returns the plugin id owning a skill with this name. Requires exactly
    # one owner; unknown/ambiguous names raise with candidates.
    def find_owner!(state, name)
      owners = owners_of(state, name)

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
                     "activate it via `clpr activate <plugin> --skill #{name}`"
      end
    end

    # Flat [name, plugin, active] rows across every plugin.
    def all_rows(state)
      rows = []
      state.plugins.each do |id, entry|
        (entry.dig("components", "skills") || {}).each_key do |name|
          active = state.profile_plugins.dig(id, "components", "skills", name, "active") ? true : false
          rows << [name, id, active]
        end
      end
      rows.sort_by { |row| [row[0], row[1]] }
    end
  end

  # Thor subcommand: clpr skill ...
  class SkillCLI < Thor
    class_option :no_color, type: :boolean, default: false

    desc "new NAME", "Create a skill you own and manage, activate it, and open it for editing"
    option :description, aliases: "-d", desc: "One-line skill description"
    def new(name)
      state = State.load
      Paths.ensure_skeleton!
      path = Skills.create_user_skill!(state, name, description: options[:description])
      Editor.edit_user_skill(State.load, name)
      Reporter.info Reporter.dim("edit again any time with `clpr edit #{name}` (#{path})")
    end

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

    desc "delete NAME", "Permanently delete a skill you created with `skill new`"
    def delete(name)
      Skills.delete_user_skill!(State.load, name)
      Reporter.ok "deleted skill #{name}"
    end
  end
end
