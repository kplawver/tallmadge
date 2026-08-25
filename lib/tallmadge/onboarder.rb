# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Tallmadge
  # Handles first-time setup and onboarding: detecting and backing up existing
  # ~/.agents directories, importing existing MCP servers, plugins, and marketplaces
  # from other harnesses, with deduplication, and configuring Tallmadge management.
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
      marketplace_findings = inspect_harness_marketplaces
      plugin_findings = inspect_harness_plugins

      if !agents_findings[:exists] && mcp_findings.empty? &&
         marketplace_findings.empty? && plugin_findings.empty?
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

      if marketplace_findings.any?
        handle_marketplace_imports(marketplace_findings, non_interactive: non_interactive, auto_yes: auto_yes)
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

    # Harness name -> candidate MCP config paths (relative to ~).
    HARNESS_MCP_PATHS = {
      "Claude" => [
        File.join("Library", "Application Support", "Claude", "claude_desktop_config.json"),
        File.join(".config", "Claude", "claude_desktop_config.json"),
        ".claude.json"
      ],
      "Cursor" => [
        File.join(".cursor", "mcp.json"),
        File.join("Library", "Application Support", "Cursor", "mcp.json")
      ],
      "Cline/Roo" => [
        File.join("Library", "Application Support", "Code", "User", "globalStorage",
                   "saoudrizwan.claude-dev", "settings", "cline_mcp_settings.json"),
        File.join(".config", "Code", "User", "globalStorage",
                   "saoudrizwan.claude-dev", "settings", "cline_mcp_settings.json"),
        File.join("Library", "Application Support", "Code", "User", "globalStorage",
                   "rooveterinaryinc.roo-cline", "settings", "cline_mcp_settings.json")
      ],
      "Oh My Pi" => [
        File.join(".omp", "agent", "mcp.json")
      ]
    }.freeze

    def inspect_mcp_configs
      findings = {}
      HARNESS_MCP_PATHS.each do |harness, rel_paths|
        rel_paths.each do |rel|
          path = File.join(Dir.home, rel)
          next unless File.file?(path)

          servers = extract_mcp_servers_from_json(path)
          findings["#{harness} (#{path})"] = { path: path, servers: servers } if servers && !servers.empty?
        end
      end
      findings
    end

    def inspect_harness_marketplaces
      findings = {}

      claude_mp_file = File.join(Dir.home, ".claude", "plugins", "known_marketplaces.json")
      data = load_json_file(claude_mp_file)
      if data.is_a?(Hash)
        data.each do |name, info|
          next unless info.is_a?(Hash)

          source = info["source"]
          repo = source.is_a?(Hash) ? (source["repo"] || source["url"]) : source
          install_loc = info["installLocation"]

          source_spec = if repo && !repo.empty?
                          repo
                        elsif install_loc && Dir.exist?(install_loc)
                          install_loc
                        end

          if source_spec
            findings["Claude Marketplace: #{name}"] = {
              name: name,
              source: source_spec,
              source_type: "claude"
            }
          end
        end
      end

      claude_settings = File.join(Dir.home, ".claude", "settings.json")
      data = load_json_file(claude_settings)
      extra = data && data["extraKnownMarketplaces"]
      if extra.is_a?(Hash)
        extra.each do |name, info|
          source = info.is_a?(Hash) ? (info["repo"] || info["url"] || info["path"]) : info
          if source && !source.empty?
            findings["Claude Settings Marketplace: #{name}"] ||= {
              name: name,
              source: source,
              source_type: "claude-settings"
            }
          end
        end
      end

      findings
    end

    def inspect_harness_plugins
      findings = {}

      claude_plugins_file = File.join(Dir.home, ".claude", "plugins", "installed_plugins.json")
      data = load_json_file(claude_plugins_file)
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

        begin
          subcomp = Store.scan_components(subdir)
          if has_any_components?(subcomp)
            findings["#{name}/#{sub} (#{subdir})"] ||= { id: "#{name}-#{sub}", path: subdir, source_type: source_type }
          end
        rescue StandardError => e
          Reporter.warn "scan failed for #{subdir}: #{e.message}"
        end
      end
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

      # Clean out section directories before importing so new symlinks don't collide
      clean_section_directories!

      import_user_files_from_backup(temp_source)
      import_components_from_backup(temp_source)
    end

    def clean_section_directories!
      Paths::SECTIONS.each do |sec|
        sec_dir = Paths.agents_section(sec)
        FileUtils.rm_rf(sec_dir) if Dir.exist?(sec_dir)
      end
      # Also remove composed files if unmanaged before recomposition
      %w[agents.md AGENTS.md mcp.json].each do |f|
        target = File.join(Paths.agents_home, f)
        File.delete(target) if File.exist?(target) && !File.symlink?(target)
      end
      Paths.ensure_skeleton!
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
      imported_count = 0

      # Components migrate as grouped plugins, not one plugin per entry:
      # symlinked entries that share a source directory (realpath parent)
      # become one plugin named for that source, and plain entries whose
      # names share a "<root>-suffix" family (caveman, caveman-commit, ...)
      # become one plugin named for the root. Family members stay
      # individually toggleable via component-level activate/deactivate.
      Paths::SECTIONS.each do |sec|
        sec_dir = File.join(backup_dir, sec)
        next unless Dir.exist?(sec_dir)

        entries = Dir.children(sec_dir).reject { |c| c.start_with?(".") }.sort
        migration_groups(sec_dir, entries).each do |base, source_path, names|
          imported_count += 1 if import_component_group(sec, sec_dir, base, source_path, names)
        end
      end

      if imported_count.positive?
        Reporter.ok "Migrated #{imported_count} standalone plugin(s) from prior ~/.agents into Tallmadge store"
      end
    end

    # Returns [base_name, source_path, [entry_names]] groups per section.
    # Symlinked entries group under their shared realpath parent (the real
    # plugin checkout); plain entries group by name-prefix family, where a
    # family root must itself be present in the same section.
    def migration_groups(sec_dir, entries)
      linked = {}
      plain = []

      entries.each do |name|
        path = File.join(sec_dir, name)
        real = File.symlink?(path) ? (File.realpath(path) rescue nil) : nil
        if real
          (linked[File.dirname(real)] ||= []) << name
        else
          plain << name
        end
      end

      groups = linked.map do |parent, names|
        base = names.size == 1 ? names.first : File.basename(File.dirname(parent))
        [base, parent, names.sort]
      end

      base_of = {}
      plain.each do |name|
        base_of[name] = File.directory?(File.join(sec_dir, name)) ? name : File.basename(name, ".*")
      end

      families = {}
      plain.each do |name|
        base = base_of[name]
        root = base_of.values.uniq
                      .select { |other| other != base && base.start_with?(other + "-") }
                      .min_by(&:length)
        (families[root || base] ||= []) << name
      end
      families.each { |base, names| groups << [base, sec_dir, names.sort] }

      groups.sort_by(&:first)
    end

    def import_component_group(sec, sec_dir, base, source_path, names)
      plugin_id = Store.derive_id(base)
      plugin_id = Store.derive_id("#{base}-#{sec.chomp('s')}") if @state.plugins.key?(plugin_id)

      # Copy component entries into a discrete standalone plugin directory in the store
      dest = Paths.plugin_dir(plugin_id)
      names.each do |entry_name|
        entry_path = File.join(sec_dir, entry_name)
        dest_entry = File.join(dest, sec, entry_name)
        FileUtils.mkdir_p(File.dirname(dest_entry))

        if File.directory?(entry_path)
          FileUtils.cp_r(entry_path, dest_entry)
        else
          FileUtils.cp(entry_path, dest_entry)
        end
      end

      # Write standalone plugin manifest
      meta_dir = File.join(dest, ".omp-plugin")
      FileUtils.mkdir_p(meta_dir)
      File.write(
        File.join(meta_dir, "plugin.json"),
        JSON.pretty_generate({
          "name" => base,
          "description" => "#{sec.capitalize} component#{names.size == 1 ? '' : 's'} migrated from prior ~/.agents"
        }) + "\n"
      )

      # Scan & register in State
      scan_result = Store.scan(dest)
      now = Time.now.utc.iso8601
      @state.plugins[plugin_id] = {
        "installedAt" => now,
        "updatedAt" => now,
        "source" => { "type" => "path", "path" => source_path },
        "components" => scan_result["components"]
      }
      entry = @state.ensure_profile_plugin!(plugin_id)
      mark_components_active!(entry)

      if names.size == 1
        Reporter.ok "Imported #{sec.chomp('s')}: #{Reporter.name(plugin_id)}"
      else
        Reporter.ok "Imported #{sec}: #{Reporter.name(plugin_id)} (#{names.size} components: #{names.join(', ')})"
      end
      true
    end

    def mark_components_active!(entry)
      (entry["components"] || {}).each do |s, items|
        if s == "agentsMd"
          items["active"] = true if items.is_a?(Hash)
        elsif items.is_a?(Hash)
          items.each_value { |info| info["active"] = true if info.is_a?(Hash) }
        end
      end
    end

    def handle_mcp_imports(mcp_findings, non_interactive: false, auto_yes: false)
      Reporter.info "\nFound external MCP server configurations:"

      candidate_servers = {}
      mcp_findings.each do |source_name, info|
        Reporter.info "  From #{source_name}:"
        info[:servers].each do |name, config|
          Reporter.info "    - #{name}: #{config['command'] || config[:command] || 'custom'}"
          candidate_servers[name] ||= { config: config, sources: [] }
          candidate_servers[name][:sources] << source_name
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

      plugin_provided_servers = {}
      @state.plugins.each do |pid, p_entry|
        p_servers = p_entry.dig("components", "mcpServers") || {}
        p_servers.each_key { |sname| plugin_provided_servers[sname] = pid }
      end

      imported_count = 0
      skipped_count = 0

      candidate_servers.each do |name, data|
        config = data[:config]
        if current_data["mcpServers"].key?(name)
          Reporter.warn "MCP server '#{name}' already present in user configuration (skipping duplicate from #{data[:sources].join(', ')})"
          skipped_count += 1
        elsif plugin_provided_servers.key?(name)
          Reporter.warn "MCP server '#{name}' already provided by plugin '#{plugin_provided_servers[name]}' (skipping duplicate)"
          skipped_count += 1
        else
          current_data["mcpServers"][name] = config
          imported_count += 1
        end
      end

      File.write(user_mcp_file, JSON.pretty_generate(current_data) + "\n")
      @state.user_content["mcpJson"] = "profiles/#{@state.active_profile_name}/mcp.json"
      Reporter.ok "Imported #{imported_count} MCP server(s) into profile '#{@state.active_profile_name}' (#{skipped_count} skipped/deduped)"
    end

    def handle_marketplace_imports(marketplace_findings, non_interactive: false, auto_yes: false)
      Reporter.info "\nFound external marketplaces from other harnesses:"
      marketplace_findings.each_key do |display|
        Reporter.info "  - #{display}"
      end

      prompt = "Import and add these marketplaces to Tallmadge?"
      should_import = auto_yes || (non_interactive ? true : prompt_yes_no(prompt, default: true))
      return unless should_import

      imported_count = 0
      skipped_count = 0

      marketplace_findings.each do |_display, info|
        name = info[:name]
        source = info[:source]

        if @state.marketplaces.key?(name)
          Reporter.info "Marketplace '#{name}' already exists in Tallmadge (skipping duplicate)"
          @state.profile_marketplaces << name unless @state.profile_marketplaces.include?(name)
          skipped_count += 1
          next
        end

        existing_with_same_source = @state.marketplaces.find do |_mname, minfo|
          msrc = minfo["source"]
          msrc && (msrc["repo"] == source || msrc["url"] == source || msrc["path"] == source)
        end

        if existing_with_same_source
          Reporter.info "Marketplace source #{source.inspect} already added as '#{existing_with_same_source[0]}' (skipping duplicate)"
          skipped_count += 1
          next
        end

        begin
          Marketplace.add(@state, source, auto_install: false)
          imported_count += 1
        rescue StandardError => e
          Reporter.err "Failed to add marketplace from #{source}: #{e.message}"
        end
      end

      @state.save
      Reporter.ok "Marketplace import complete: #{imported_count} added, #{skipped_count} skipped/deduped."
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
      imported_count = 0
      skipped_count = 0

      plugin_findings.each do |_display, info|
        raw_id = info[:id] || info[:path]
        id = Store.derive_id(raw_id)
        source_path = File.expand_path(info[:path])

        if @state.plugins.key?(id)
          existing_path = @state.plugins[id].dig("source", "path")
          if existing_path && File.expand_path(existing_path) == source_path
            Reporter.info "Plugin '#{id}' already installed from #{source_path} (skipping duplicate)"
            skipped_count += 1
            next
          end
        end

        duplicate_source = @state.plugins.find do |_pid, pinfo|
          psrc = pinfo["source"]
          psrc && psrc["type"] == "path" && psrc["path"] && File.expand_path(psrc["path"]) == source_path
        end

        if duplicate_source
          Reporter.info "Plugin at #{source_path} already installed as '#{duplicate_source[0]}' (skipping duplicate)"
          skipped_count += 1
          next
        end

        begin
          candidate_comp = Store.scan_components(source_path)
          matching_plugin = @state.plugins.find do |_pid, pentry|
            existing_comp = pentry["components"] || {}
            same_skills = candidate_comp["skills"].keys.sort == (existing_comp["skills"] || {}).keys.sort
            same_agents = candidate_comp["agents"].keys.sort == (existing_comp["agents"] || {}).keys.sort
            !candidate_comp["skills"].empty? && same_skills && same_agents
          end

          if matching_plugin
            Reporter.info "Plugin components from #{source_path} already provided by '#{matching_plugin[0]}' (skipping duplicate)"
            skipped_count += 1
            next
          end
        rescue StandardError => e
          Reporter.warn "scan failed for #{source_path}: #{e.message}; attempting install anyway"
        end

        begin
          installer.install_path(info[:path], as: id, force: true)
          # Mark active in profile state; linking deferred to finalize_setup
          entry = @state.ensure_profile_plugin!(id)
          mark_components_active!(entry)
          Reporter.ok "Imported plugin #{Reporter.name(id)}"
          imported_count += 1
        rescue StandardError => e
          Reporter.err "Failed to import plugin from #{info[:path]}: #{e.message}"
        end
      end

      Reporter.ok "Plugin import complete: #{imported_count} imported, #{skipped_count} skipped/deduped."
    end

    def finalize_setup
      clean_section_directories!
      if @state.plugins.any? || @state.user_content["agentsMd"] || @state.user_content["mcpJson"]
        Activator.new(@state).apply_profile!
      end
      @state.save
    end

    def restore(backup_path: nil, non_interactive: false, auto_yes: false)
      Reporter.info "=== Tallmadge Management Removal & Restore ==="

      backups = Dir.glob(File.join(Paths.backups_dir, "*-agents-backup")).sort
      target_backup = backup_path || backups.last

      if target_backup.nil? || !Dir.exist?(target_backup)
        raise Error, "No ~/.agents backup found in #{Paths.backups_dir} to restore from."
      end

      Reporter.info "Target backup to restore: #{target_backup}"
      prompt = "This will remove all Tallmadge symlinks, unmanage ~/.agents, and restore #{target_backup}. Proceed?"
      should_proceed = auto_yes || (non_interactive ? true : prompt_yes_no(prompt, default: true))
      return unless should_proceed

      # 1. Teardown active profile symlinks and bridge links
      Activator.new(@state).teardown_profile!

      # 2. Clear current ~/.agents directory
      FileUtils.rm_rf(Paths.agents_home)

      # 3. Restore backup to ~/.agents
      FileUtils.cp_r(target_backup, Paths.agents_home)
      Reporter.ok "Restored ~/.agents from #{target_backup}"

      # 4. Remove managed state for userContent and composed files
      @state.user_content["agentsMd"] = nil
      @state.user_content["mcpJson"] = nil
      @state.composed["agentsMd"] = false
      @state.composed["mcpJson"] = false
      @state.mcp_origins.clear
      @state.save

      Reporter.ok "Tallmadge management removed and ~/.agents restored successfully."
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
      data = load_json_file(path)
      return {} unless data.is_a?(Hash)

      servers = data["mcpServers"] || data["mcp_servers"]
      servers.is_a?(Hash) ? servers : {}
    end

    # Parse a JSON file, returning nil when missing or unparseable.
    def load_json_file(path)
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError, Errno::ENOENT
      nil
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
