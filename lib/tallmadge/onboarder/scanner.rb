# frozen_string_literal: true

require "json"

module Tallmadge
  class Onboarder
    # Read-only detection of existing ~/.agents content and external
    # harness configurations (MCP servers, marketplaces, plugins).
    # Returns plain findings hashes; does not mutate state.
    module Scanner
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
    end
  end
end
