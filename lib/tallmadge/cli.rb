# frozen_string_literal: true

module Tallmadge
  class CLI < Thor
    package_name "clpr"

    class_option :no_color, type: :boolean, default: false,
                            desc: "Disable colored output"

    default_task :help

    desc "marketplace SUBCOMMAND", "Manage plugin marketplaces"
    subcommand "marketplace", MarketplaceCLI

    desc "hub SUBCOMMAND", "Browse and install .agents Hub bundles"
    subcommand "hub", HubCLI

    desc "skill SUBCOMMAND", "Activate or deactivate a single skill by name"
    subcommand "skill", SkillCLI

    desc "profile SUBCOMMAND", "Manage profiles (switchable plugin/marketplace/content sets)"
    subcommand "profile", ProfileCLI

    def self.exit_on_failure?
      true
    end

    # Central error wiring: Tallmadge::Error -> red message + exit 1.
    # Color is disabled before Thor parses, so early failures honor it too.
    def self.start(given_args = ARGV, config = {})
      args = Array(given_args)
      Rainbow.enabled = false if ENV["NO_COLOR"] || args.include?("--no-color")
      super
    rescue Tallmadge::Error => e
      Reporter.err(e.message)
      exit(1)
    end

    desc "version", "Print the clpr version"
    map %w[--version -v] => :version
    def version
      puts "clpr #{Tallmadge::VERSION}"
    end

    desc "setup", "Run setup and onboarding (backup existing .agents, import MCP configs and plugins)"
    option :yes, aliases: "-y", type: :boolean, desc: "Automatically accept all prompts"
    option :non_interactive, type: :boolean, desc: "Run non-interactively"
    def setup
      state = State.load
      Onboarder.new(state).run(non_interactive: options[:non_interactive], auto_yes: options[:yes])
    end

    desc "restore", "Remove Tallmadge management and restore backed-up ~/.agents directory"
    option :from, desc: "Specific backup directory path to restore from"
    option :yes, aliases: "-y", type: :boolean, desc: "Automatically accept prompts"
    option :non_interactive, type: :boolean, desc: "Run non-interactively"
    def restore
      state = State.load
      Onboarder.new(state).restore(backup_path: options[:from], non_interactive: options[:non_interactive], auto_yes: options[:yes])
    end

    desc "init", "Create the ~/.tallmadge and ~/.agents directory skeleton"
    option :onboard, type: :boolean, desc: "Run onboarding during initialization"
    option :yes, aliases: "-y", type: :boolean, desc: "Automatically accept all prompts during onboarding"
    def init
      if options[:onboard]
        setup
        return
      end

      created = Paths.ensure_skeleton!
      if created.empty?
        Reporter.ok "skeleton already present (#{Paths.tallmadge_home}, #{Paths.agents_home})"
      else
        created.each { |dir| Reporter.ok "created #{dir}" }
      end
    end

    desc "install SPEC", "Install a plugin from a path, git URL, owner/repo, marketplace, or hub"
    option :as, desc: "Install under this plugin id"
    option :force, type: :boolean, desc: "Replace an existing install with the same id"
    def install(spec)
      Installer.new(State.load).install(spec, as: options[:as], force: options[:force])
    end

    desc "activate ID", "Symlink a plugin's components into ~/.agents (and compose agents.md/mcp.json)"
    option :skill, desc: "Activate only this skill"
    option :agent, desc: "Activate only this agent"
    option :task, desc: "Activate only this task"
    option :memory, desc: "Activate only this memory file"
    option :force, type: :boolean, desc: "Back up and replace conflicting targets"
    def activate(id)
      state = State.load
      Paths.ensure_skeleton!
      Activator.new(state).activate(id, only: component_filter, force: options[:force])
    end

    desc "deactivate ID", "Remove a plugin's links from ~/.agents (and recompose)"
    option :skill, desc: "Deactivate only this skill"
    option :agent, desc: "Deactivate only this agent"
    option :task, desc: "Deactivate only this task"
    option :memory, desc: "Deactivate only this memory file"
    def deactivate(id)
      Activator.new(State.load).deactivate(id, only: component_filter)
    end

    desc "search [QUERY]", "Search all marketplaces and the hub catalog"
    def search(query = nil)
      Marketplace.search(State.load, query)
    end

    desc "update [ID]", "Check installed plugins for updates"
    option :apply, type: :boolean, desc: "Reinstall plugins that have updates"
    def update(id = nil)
      Updater.run(State.load, id: id, apply: options[:apply])
    end

    desc "list", "List installed plugins and their components"
    def list
      state = State.load
      if state.plugins.empty?
        Reporter.info "no plugins installed"
        return
      end

      state.plugins.each do |id, entry|
        prof_entry = state.profile_plugins[id]
        puts "#{Reporter.name(id)}  #{Reporter.dim(source_summary(entry['source']))}"
        puts "  installed #{entry['installedAt']}  updated #{entry['updatedAt']}"
        (entry["components"] || {}).each do |section, items|
          next if items.nil? || items.empty?

          if section == "agentsMd"
            active = prof_entry&.dig("components", "agentsMd", "active") ? true : false
            puts "  #{Reporter.active_marker(active)} agents.md"
            next
          end
          items.each_key do |comp_name|
            active = prof_entry&.dig("components", section, comp_name, "active") ? true : false
            puts "  #{Reporter.active_marker(active)} #{section}: #{comp_name}"
          end
        end
        puts
      end
    end

    desc "uninstall ID", "Uninstall a plugin (deactivates, then removes its store copy)"
    def uninstall(id)
      state = State.load
      entry = state.plugins[id]
      unless entry
        installed = state.plugins.keys
        msg = "unknown plugin '#{id}'"
        msg += " — installed: #{installed.join(', ')}" unless installed.empty?
        raise Error, msg
      end

      Activator.new(state).deactivate(id)
      FileUtils.rm_rf(Paths.plugin_dir(id))
      state.plugins.delete(id)
      state.profiles.each_value do |prof|
        prof["plugins"].delete(id)
        prof["mcpOrigins"].delete_if { |_, origin| origin == id }
      end
      state.save
      Reporter.ok "uninstalled #{id}"
    end

    desc "link [HARNESS]", "Bridge harness gaps (default: all detected harnesses)"
    option :force, type: :boolean, desc: "Back up and replace conflicting targets"
    def link(harness = nil)
      state = State.load
      Paths.ensure_skeleton!
      Harness.link(state, harness, force: options[:force])
    end

    desc "skills", "List every skill across installed plugins"
    def skills
      rows = Skills.all_rows(State.load)
      if rows.empty?
        Reporter.info "no skills installed"
        return
      end

      table_rows = rows.map do |name, plugin_id, active|
        status = active ? Rainbow("active").green.to_s : Rainbow("inactive").faint.to_s
        [name, plugin_id, status]
      end
      Reporter.table(table_rows, %w[skill plugin active])
    end

    desc "unlink HARNESS", "Remove every bridge link for a harness"
    def unlink(harness)
      Harness.unlink(State.load, harness)
    end

    desc "doctor", "Check tallmadge state, links, and unmanaged content"
    def doctor
      errors = Harness.doctor(State.load)
      exit(errors.positive? ? 1 : 0)
    end

    no_commands do
      def source_summary(src)
        case src && src["type"]
        when "git" then "git #{src['url']} @ #{(src['sha'] || 'HEAD')[0, 7]}"
        when "path" then "path #{src['path']}"
        when "marketplace"
          base = "marketplace #{src['marketplace']}/#{src['plugin']}"
          src["version"] ? "#{base} v#{src['version']}" : base
        when "hub" then "hub bundle #{src['bundleId']} v#{src['bundleVersion']}"
        else "unknown source"
        end
      end

      def component_filter
        pairs = []
        pairs << ["skills", options[:skill]] if options[:skill]
        pairs << ["agents", options[:agent]] if options[:agent]
        pairs << ["tasks", options[:task]] if options[:task]
        pairs << ["memories", options[:memory]] if options[:memory]
        pairs.empty? ? nil : pairs
      end
    end
  end
end
