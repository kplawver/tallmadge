# frozen_string_literal: true

module Tallmadge
  # Plugin-id derivation, component scanning, and store-copy helpers.
  module Store
    INACTIVE = { "active" => false }.freeze

    module_function

    # repo basename without .git, path basename; lowercased, sanitized to
    # [a-z0-9.-].
    def derive_id(spec)
      base = spec.to_s.sub(%r{\A~[/\\]}, "")
      base = base.sub(%r{\.git\z}i, "")
      base = File.basename(base)
      id = base.downcase.gsub(/[^a-z0-9.\-]+/, "-").gsub(/\A[.\-]+|[.\-]+\z/, "")
      if id.empty?
        raise Error, "cannot derive a plugin id from #{spec.inspect} (use --as ID)"
      end

      id
    end

    # Copies src into dest, replacing anything present, excluding .git.
    def copy_into(src, dest)
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp_r(src, dest)
      FileUtils.rm_rf(File.join(dest, ".git"))
      dest
    end

    # Path of the Claude/omp marketplace catalog inside dir, or nil.
    def marketplace_catalog_path(dir)
      %w[.claude-plugin/marketplace.json .omp-plugin/marketplace.json].each do |rel|
        path = File.join(dir, rel)
        return path if File.file?(path)
      end
      nil
    end

    # Returns {"components" => ..., "displayName" => ..., "description" => ...}.
    # Components mirror the state schema; everything starts inactive.
    def scan(dir)
      components = scan_components(dir)
      display_name = nil
      description = nil

      %w[.claude-plugin .omp-plugin].each do |meta_dir|
        plugin_json = File.join(dir, meta_dir, "plugin.json")
        next unless File.file?(plugin_json)

        data = JSON.parse(File.read(plugin_json)) rescue {}
        display_name ||= data["name"]
        description ||= data["description"]
      end

      display_name ||= File.basename(dir)
      description ||= first_skill_description(dir, components)

      { "components" => components,
        "displayName" => display_name,
        "description" => description }
    end

    def scan_components(dir)
      components = {
        "skills" => {}, "agents" => {}, "tasks" => {}, "memories" => {},
        "mcpServers" => {}, "agentsMd" => nil, "hooks" => {}
      }
      scan_skills(dir, components)
      scan_agents(dir, components)
      scan_tasks(dir, components)
      scan_memories(dir, components)
      scan_mcp(dir, components)
      scan_hooks(dir, components)
      scan_agents_md(dir, components)
      components
    end

    def scan_skills(dir, components)
      skills_dir = File.join(dir, "skills")
      if Dir.exist?(skills_dir)
        Dir.children(skills_dir).sort.each do |entry|
          sub = File.join(skills_dir, entry)
          next unless Dir.exist?(sub)

          components["skills"][entry] = inactive if child_ci?(sub, "SKILL.md")
        end
      elsif child_ci?(dir, "SKILL.md")
        # Single-skill repo/dir: named after the directory basename.
        components["skills"][File.basename(dir)] = inactive
      end
    end

    def scan_agents(dir, components)
      agents_dir = File.join(dir, "agents")
      return unless Dir.exist?(agents_dir)

      Dir.children(agents_dir).sort.each do |entry|
        full = File.join(agents_dir, entry)
        if Dir.exist?(full)
          components["agents"][entry] = inactive if child_ci?(full, "agent.md")
        elsif File.extname(entry).casecmp?(".md")
          components["agents"][File.basename(entry, File.extname(entry))] = inactive
        end
      end
    end

    def scan_tasks(dir, components)
      tasks_dir = File.join(dir, "tasks")
      return unless Dir.exist?(tasks_dir)

      Dir.children(tasks_dir).sort.each do |entry|
        sub = File.join(tasks_dir, entry)
        next unless Dir.exist?(sub)

        components["tasks"][entry] = inactive if child_ci?(sub, "task.md")
      end
    end

    def scan_memories(dir, components)
      memories_dir = File.join(dir, "memories")
      return unless Dir.exist?(memories_dir)

      Dir.children(memories_dir).sort.each do |entry|
        next unless File.extname(entry).casecmp?(".md")
        next unless File.file?(File.join(memories_dir, entry))

        components["memories"][entry] = inactive
      end
    end

    def scan_mcp(dir, components)
      mcp_servers_in(dir).each_key { |name| components["mcpServers"][name] = inactive }
    end

    def scan_hooks(dir, components)
      hooks_in(dir).each_key { |hook_id| components["hooks"][hook_id] = inactive }
    end

    # {hook_id => {"event", "matcher", "handler"}} from hooks/hooks.json plus
    # whatever the plugin manifest's "hooks" key declares. Ids hash the
    # handler's content, so an updated command is a new, inactive hook.
    def hooks_in(dir)
      hook_event_maps(dir).each_with_object({}) do |event_map, found|
        event_map.each do |event, groups|
          Array(groups).each do |group|
            next unless group.is_a?(Hash)

            Array(group["hooks"]).each do |handler|
              next unless handler.is_a?(Hash)

              found[hook_id(event, group["matcher"], handler)] =
                { "event" => event, "matcher" => group["matcher"], "handler" => handler }
            end
          end
        end
      end
    end

    # hooks for an installed plugin.
    def hooks(id)
      hooks_in(Paths.plugin_dir(id))
    end

    def hook_id(event, matcher, handler)
      digest = Digest::SHA256.hexdigest(JSON.generate(canonical([event, matcher, handler])))
      "#{event}:#{digest[0, 8]}"
    end

    # Recursively key-sorted copy so key order never changes a hook id.
    def canonical(value)
      case value
      when Hash then value.sort.to_h { |k, v| [k, canonical(v)] }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    # Event maps (event => matcher groups) from hooks/hooks.json (wrapped in
    # a top-level "hooks" key) and the manifest's hooks key: a path to such
    # a file, an inline event map, or an array of either.
    def hook_event_maps(dir)
      maps = [hooks_file_map(File.join(dir, "hooks", "hooks.json"), dir)]
      %w[.claude-plugin .omp-plugin].each do |meta_dir|
        manifest = File.join(dir, meta_dir, "plugin.json")
        next unless File.file?(manifest)

        data = JSON.parse(File.read(manifest)) rescue {}
        entries = data["hooks"].is_a?(Array) ? data["hooks"] : [data["hooks"]].compact
        entries.each do |entry|
          maps << (entry.is_a?(String) ? hooks_file_map(File.expand_path(entry, dir), dir) : entry)
        end
      end
      maps.select { |m| m.is_a?(Hash) }
    end

    # Event map from a hooks file; {} when absent, invalid, or outside dir.
    def hooks_file_map(path, dir)
      return {} unless path.start_with?(File.expand_path(dir) + File::SEPARATOR) && File.file?(path)

      data = JSON.parse(File.read(path)) rescue {}
      data.is_a?(Hash) ? data["hooks"] : {}
    end

    # mcpServers map from dir's mcp.json/.mcp.json; {} when absent or invalid.
    def mcp_servers_in(dir)
      file = %w[mcp.json .mcp.json].map { |f| File.join(dir, f) }.find { |f| File.file?(f) }
      return {} unless file

      data = JSON.parse(File.read(file)) rescue {}
      servers = data["mcpServers"]
      servers.is_a?(Hash) ? servers : {}
    end

    # mcpServers map for an installed plugin.
    def mcp_servers(id)
      mcp_servers_in(Paths.plugin_dir(id))
    end

    def scan_agents_md(dir, components)
      components["agentsMd"] = INACTIVE.dup if child_ci?(dir, "agents.md")
    end

    # Case-insensitive child file check.
    def child_ci?(dir, filename)
      Dir.children(dir).any? do |entry|
        entry.casecmp?(filename) && File.file?(File.join(dir, entry))
      end
    end

    def first_skill_description(dir, components)
      name = components["skills"].keys.first
      return nil unless name

      skill_dir = File.join(dir, "skills", name)
      file =
        if Dir.exist?(skill_dir)
          entry = Dir.children(skill_dir).find { |e| e.casecmp?("SKILL.md") }
          entry && File.join(skill_dir, entry)
        elsif child_ci?(dir, "SKILL.md")
          entry = Dir.children(dir).find { |e| e.casecmp?("SKILL.md") }
          entry && File.join(dir, entry)
        end
      return nil unless file

      meta, = Frontmatter.parse(File.read(file))
      meta["description"]
    end

    def inactive
      INACTIVE.dup
    end
  end
end
