# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Tallmadge
  # Handles first-time setup and onboarding: detecting and backing up existing
  # ~/.agents directories, importing existing MCP servers and harness plugins,
  # and configuring Tallmadge management without destroying user configurations.
  class Onboarder
    attr_reader :state, :input, :output

    def initialize(state, input: $stdin, output: $stdout)
      @state = state
      @input = input
      @output = output
    end

    def run(non_interactive: false, auto_yes: false)
      Reporter.info "=== Tallmadge Setup & Onboarding ==="

      agents_findings = inspect_agents_dir
      mcp_findings = inspect_mcp_configs
      plugin_findings = inspect_harness_plugins

      if !agents_findings[:exists] && mcp_findings.empty? && plugin_findings.empty?
        Reporter.info "No existing unmanaged .agents directory or external configurations detected."
        created = Paths.ensure_skeleton!
        created.each { |dir| Reporter.ok "created #{dir}" }
        Reporter.ok "Tallmadge initialized successfully."
        return
      end

      if agents_findings[:exists]
        if agents_findings[:managed]
          Reporter.ok "~/.agents is already managed by Tallmadge."
        else
          handle_agents_migration(agents_findings, non_interactive: non_interactive, auto_yes: auto_yes)
        end
      else
        Paths.ensure_skeleton!
      end

      if mcp_findings.any?
        handle_mcp_imports(mcp_findings, non_interactive: non_interactive, auto_yes: auto_yes)
      end

      if plugin_findings.any?
        handle_plugin_imports(plugin_findings, non_interactive: non_interactive, auto_yes: auto_yes)
      end

      finalize_setup
      Reporter.ok "Setup and onboarding complete!"
    end

    # --- Inspection methods ---

    def inspect_agents_dir
      dir = Paths.agents_home
      return { exists: false } unless Dir.exist?(dir)

      entries = Dir.children(dir).reject { |c| c.start_with?(".") }
      return { exists: false } if entries.empty?

      store_base = File.realpath(Paths.store_dir) rescue nil

      # Check unmanaged items
      unmanaged_items = []
      managed_items = []

      entries.each do |entry|
        path = File.join(dir, entry)
        if Paths::SECTIONS.include?(entry) && Dir.exist?(path)
          Dir.children(path).reject { |c| c.start_with?(".") }.each do |child|
            child_path = File.join(path, child)
            if tallmadge_symlink?(child_path, store_base)
              managed_items << child_path
            else
              unmanaged_items << child_path
            end
          end
        elsif entry.casecmp?("agents.md")
          if agents_md_managed?(path)
            managed_items << path
          else
            unmanaged_items << path
          end
        elsif entry.casecmp?("mcp.json")
          if @state.composed["mcpJson"]
            managed_items << path
          else
            unmanaged_items << path
          end
        else
          unmanaged_items << path
        end
      end

      is_fully_managed = unmanaged_items.empty? && managed_items.any?

      skills = safe_dir_children(Paths.agents_section("skills"))
      agents = safe_dir_children(Paths.agents_section("agents"))
      tasks = safe_dir_children(Paths.agents_section("tasks"))
      memories = safe_dir_children(Paths.agents_section("memories"))

      has_agents_md = File.exist?(File.join(dir, "agents.md")) || File.exist?(File.join(dir, "AGENTS.md"))
      has_mcp_json = File.exist?(File.join(dir, "mcp.json"))

      {
        exists: true,
        managed: is_fully_managed,
        path: dir,
        entries: entries,
        unmanaged_items: unmanaged_items,
        managed_items: managed_items,
        skills: skills,
        agents: agents,
        tasks: tasks,
        memories: memories,
        has_agents_md: has_agents_md,
        has_mcp_json: has_mcp_json
      }
    end

    def inspect_mcp_configs
      findings = {}
      inspect_claude_mcp(findings)
      inspect_cursor_mcp(findings)
      inspect_cline_mcp(findings)
      inspect_omp_mcp(findings)
      findings
    end

    def inspect_claude_mcp(findings)
      paths = [
        File.join(Dir.home, "Library", "Application Support", "Claude", "claude_desktop_config.json"),
        File.join(Dir.home, ".config", "Claude", "claude_desktop_config.json"),
        File.join(Dir.home, ".claude.json")
      ]
      paths.each do |path|
        next unless File.file?(path)

        servers = extract_mcp_servers_from_json(path)
        findings["Claude (#{path})"] = { path: path, servers: servers } if servers && !servers.empty?
      end
    end

    def inspect_cursor_mcp(findings)
      paths = [
        File.join(Dir.home, ".cursor", "mcp.json"),
        File.join(Dir.home, "Library", "Application Support", "Cursor", "mcp.json")
      ]
      paths.each do |path|
        next unless File.file?(path)

        servers = extract_mcp_servers_from_json(path)
        findings["Cursor (#{path})"] = { path: path, servers: servers } if servers && !servers.empty?
      end
    end

    def inspect_cline_mcp(findings)
      paths = [
        File.join(Dir.home, "Library", "Application Support", "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "settings", "cline_mcp_settings.json"),
        File.join(Dir.home, ".config", "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "settings", "cline_mcp_settings.json"),
        File.join(Dir.home, "Library", "Application Support", "Code", "User", "globalStorage", "rooveterinaryinc.roo-cline", "settings", "cline_mcp_settings.json")
      ]
      paths.each do |path|
        next unless File.file?(path)

        servers = extract_mcp_servers_from_json(path)
        findings["Cline/Roo (#{path})"] = { path: path, servers: servers } if servers && !servers.empty?
      end
    end

    def inspect_omp_mcp(findings)
      omp_mcp = File.join(Dir.home, ".omp", "agent", "mcp.json")
      return unless File.file?(omp_mcp)

      servers = extract_mcp_servers_from_json(omp_mcp)
      findings["Oh My Pi (#{omp_mcp})"] = { path: omp_mcp, servers: servers } if servers && !servers.empty?
    end

    def inspect_harness_plugins
      findings = {}

      claude_plugins_file = File.join(Dir.home, ".claude", "plugins", "installed_plugins.json")
      if File.file?(claude_plugins_file)
        data = JSON.parse(File.read(claude_plugins_file)) rescue nil
        if data.is_a?(Hash)
          entries = data["plugins"].is_a?(Hash) ? data["plugins"] : data
          entries.each do |id, info|
            next unless info.is_a?(Hash)

            path = info["installPath"]
            if path && Dir.exist?(path)
              findings["Claude: #{id}"] = { id: id, path: path, source_type: "claude" }
            end
          end
        end
      end

      claude_cache = File.join(Dir.home, ".claude", "plugins", "cache")
      if Dir.exist?(claude_cache)
        Dir.children(claude_cache).each do |child|
          dir = File.join(claude_cache, child)
          next unless Dir.exist?(dir)

          scan_and_add_plugin_findings(child, dir, findings, "claude-cache")
        end
      end

      findings
    end

    def scan_and_add_plugin_findings(name, dir, findings, source_type)
      components = Store.scan_components(dir) rescue nil
      if has_any_components?(components)
        findings["#{name} (#{dir})"] ||= { id: name, path: dir, source_type: source_type }
        return
      end

      Dir.children(dir).each do |sub|
        subdir = File.join(dir, sub)
        next unless Dir.exist?(subdir)

        subcomp = Store.scan_components(subdir) rescue nil
        if has_any_components?(subcomp)
          findings["#{name}/#{sub} (#{subdir})"] ||= { id: "#{name}-#{sub}", path: subdir, source_type: source_type }
        end
      end rescue nil
    end

    def has_any_components?(components)
      return false unless components

      components["skills"].any? || components["agents"].any? ||
        components["tasks"].any? || components["mcpServers"].any? ||
        components["memories"].any? || !components["agentsMd"].nil?
    end

    # --- Handling migration and imports ---

    def handle_agents_migration(findings, non_interactive: false, auto_yes: false)
      Reporter.info "\nFound existing unmanaged ~/.agents directory with:"
      Reporter.info "  Skills: #{findings[:skills].size}, Agents: #{findings[:agents].size}, Tasks: #{findings[:tasks].size}, Memories: #{findings[:memories].size}"
      Reporter.info "  agents.md: #{findings[:has_agents_md] ? 'present' : 'none'}, mcp.json: #{findings[:has_mcp_json] ? 'present' : 'none'}"

      prompt = "Would you like to safely back up ~/.agents and import its contents into Tallmadge management?"
      should_migrate = auto_yes || (non_interactive ? true : prompt_yes_no(prompt, default: true))
      return unless should_migrate

      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      backup_dest = File.join(Paths.backups_dir, "#{stamp}-agents-backup")
      FileUtils.mkdir_p(Paths.backups_dir)

      Reporter.info "Backing up ~/.agents to #{backup_dest}..."
      FileUtils.cp_r(Paths.agents_home, backup_dest)
      Reporter.ok "Backup saved to #{backup_dest}"

      temp_source = backup_dest

      # Move original directory out of the way and create clean skeleton
      FileUtils.rm_rf(Paths.agents_home)
      Paths.ensure_skeleton!

      import_user_files_from_backup(temp_source)
      import_components_from_backup(temp_source)
    end

    def import_user_files_from_backup(backup_dir)
      profile_dir = Paths.profile_dir(@state.active_profile_name)
      FileUtils.mkdir_p(profile_dir)

      %w[agents.md AGENTS.md].each do |name|
        src = File.join(backup_dir, name)
        if File.file?(src)
          dest = File.join(profile_dir, "agents.md")
          FileUtils.cp(src, dest)
          @state.user_content["agentsMd"] = "profiles/#{@state.active_profile_name}/agents.md"
          Reporter.ok "Imported #{name} as user content in profile '#{@state.active_profile_name}'"
          break
        end
      end

      mcp_src = File.join(backup_dir, "mcp.json")
      if File.file?(mcp_src)
        dest = File.join(profile_dir, "mcp.json")
        FileUtils.cp(mcp_src, dest)
        @state.user_content["mcpJson"] = "profiles/#{@state.active_profile_name}/mcp.json"
        Reporter.ok "Imported mcp.json as user content in profile '#{@state.active_profile_name}'"
      end
    end

    def import_components_from_backup(backup_dir)
      components_exist = Paths::SECTIONS.any? do |sec|
        sec_dir = File.join(backup_dir, sec)
        Dir.exist?(sec_dir) && Dir.children(sec_dir).reject { |c| c.start_with?(".") }.any?
      end

      return unless components_exist

      plugin_id = "imported-agents"
      dest = Paths.plugin_dir(plugin_id)
      FileUtils.mkdir_p(dest)

      Paths::SECTIONS.each do |sec|
        sec_dir = File.join(backup_dir, sec)
        next unless Dir.exist?(sec_dir)

        dest_sec = File.join(dest, sec)
        FileUtils.mkdir_p(dest_sec)
        FileUtils.cp_r(File.join(sec_dir, "."), dest_sec)
      end

      meta_dir = File.join(dest, ".omp-plugin")
      FileUtils.mkdir_p(meta_dir)
      File.write(
        File.join(meta_dir, "plugin.json"),
        JSON.pretty_generate({ "name" => "Imported Agents", "description" => "Components migrated from prior ~/.agents" }) + "\n"
      )

      scan_result = Store.scan(dest)
      now = Time.now.utc.iso8601
      @state.plugins[plugin_id] = {
        "installedAt" => now,
        "updatedAt" => now,
        "source" => { "type" => "path", "path" => backup_dir },
        "components" => scan_result["components"]
      }
      @state.ensure_profile_plugin!(plugin_id)

      Activator.new(@state).activate(plugin_id)
      Reporter.ok "Migrated existing #{plugin_id} into Tallmadge store and activated all components"
    end

    def handle_mcp_imports(mcp_findings, non_interactive: false, auto_yes: false)
      Reporter.info "\nFound external MCP server configurations:"

      mcp_findings.each do |source_name, info|
        Reporter.info "  From #{source_name}:"
        info[:servers].each do |name, config|
          Reporter.info "    - #{name}: #{config['command'] || config[:command] || 'custom'}"
        end
      end

      prompt = "Import these MCP servers into Tallmadge configuration?"
      should_import = auto_yes || (non_interactive ? true : prompt_yes_no(prompt, default: true))
      return unless should_import

      profile_dir = Paths.profile_dir(@state.active_profile_name)
      FileUtils.mkdir_p(profile_dir)
      user_mcp_file = File.join(profile_dir, "mcp.json")

      current_data = if File.file?(user_mcp_file)
                       JSON.parse(File.read(user_mcp_file)) rescue { "mcpServers" => {} }
                     else
                       { "mcpServers" => {} }
                     end
      current_data["mcpServers"] ||= {}

      imported_count = 0
      mcp_findings.each do |_source_name, info|
        info[:servers].each do |name, config|
          if current_data["mcpServers"].key?(name)
            Reporter.warn "MCP server '#{name}' already present in user configuration, keeping existing."
          else
            current_data["mcpServers"][name] = config
            imported_count += 1
          end
        end
      end

      File.write(user_mcp_file, JSON.pretty_generate(current_data) + "\n")
      @state.user_content["mcpJson"] = "profiles/#{@state.active_profile_name}/mcp.json"
      Reporter.ok "Imported #{imported_count} MCP server(s) into profile '#{@state.active_profile_name}'"
    end

    def handle_plugin_imports(plugin_findings, non_interactive: false, auto_yes: false)
      Reporter.info "\nFound external plugins from other harnesses:"
      plugin_findings.each_key do |display|
        Reporter.info "  - #{display}"
      end

      prompt = "Import and manage these plugins in Tallmadge?"
      should_import = auto_yes || (non_interactive ? true : prompt_yes_no(prompt, default: true))
      return unless should_import

      installer = Installer.new(@state)
      plugin_findings.each do |_display, info|
        id = Store.derive_id(info[:id] || info[:path])
        begin
          installer.install_path(info[:path], as: id, force: true)
          Activator.new(@state).activate(id)
          Reporter.ok "Imported and activated plugin #{Reporter.name(id)}"
        rescue StandardError => e
          Reporter.err "Failed to import plugin from #{info[:path]}: #{e.message}"
        end
      end
    end

    def finalize_setup
      Paths.ensure_skeleton!
      if @state.plugins.any? || @state.user_content["agentsMd"] || @state.user_content["mcpJson"]
        Activator.new(@state).apply_profile!
      end
      @state.save
    end

    # --- Helper methods ---

    def tallmadge_symlink?(path, store_base)
      return false unless File.symlink?(path)

      real = File.realpath(path) rescue nil
      store_base && real && real.start_with?(store_base + File::SEPARATOR)
    end

    def agents_md_managed?(target)
      File.open(target, &:readline).strip == Activator::AGENTS_MD_MARKER
    rescue StandardError
      false
    end

    def safe_dir_children(dir)
      return [] unless Dir.exist?(dir)

      Dir.children(dir).reject { |c| c.start_with?(".") }
    rescue StandardError
      []
    end

    def extract_mcp_servers_from_json(path)
      content = File.read(path)
      data = JSON.parse(content) rescue nil
      return {} unless data.is_a?(Hash)

      servers = data["mcpServers"] || data["mcp_servers"]
      servers.is_a?(Hash) ? servers : {}
    end

    def prompt_yes_no(prompt, default: true)
      default_str = default ? "[Y/n]" : "[y/N]"
      @output.print "#{prompt} #{default_str} "
      answer = @input.gets&.strip&.downcase
      return default if answer.nil? || answer.empty?

      answer.start_with?("y")
    end
  end
end
