# frozen_string_literal: true

module Tallmadge
  # The activation engine. Activating a component symlinks its store copy
  # into the matching ~/.agents section; agents.md and mcp.json are composed
  # files, never symlinked. Every activate/deactivate recomposes both files
  # and lets Harness.maintain! refresh gap-bridging links.
  class Activator
    AGENTS_MD_MARKER = "<!-- managed by tallmadge -->"
    LINK_SECTIONS = %w[skills agents tasks memories].freeze

    attr_reader :state

    def initialize(state)
      @state = state
    end

    # only: nil (all components) or an array of [section, name] pairs;
    # agentsMd is ["agentsMd", nil].
    def activate(id, only: nil, force: false)
      entry = plugin_entry(id)
      pairs = selection(entry, only)
      if pairs.empty?
        Reporter.warn "#{id}: nothing to activate"
        return
      end

      linked = 0
      pairs.each do |section, name|
        mark_active(entry, section, name, true)
        next if section == "agentsMd" || section == "mcpServers"

        source = component_source(id, section, name)
        target = component_target(section, name, source)
        link!(source, target, id, section, name, force)
        linked += 1
      end

      @state.save
      compose_agents_md!
      compose_mcp_json!
      @state.save
      maintain_harnesses
      Reporter.ok "activated #{Reporter.name(id)}" +
                  (only ? " (#{linked} link#{linked == 1 ? '' : 's'} + composed)" : "")
    end

    def deactivate(id, only: nil)
      entry = plugin_entry(id)
      pairs = selection(entry, only)
      removed = 0

      pairs.each do |section, name|
        info = component_info(entry, section, name)
        next unless info && info["active"]

        mark_active(entry, section, name, false)
        next if section == "agentsMd" || section == "mcpServers"

        source = component_source(id, section, name)
        target = component_target(section, name, source)
        removed += 1 if unlink!(target, id, section, name)
      end

      @state.save
      compose_agents_md!
      compose_mcp_json!
      @state.save
      maintain_harnesses
      Reporter.ok "deactivated #{Reporter.name(id)}"
    end

    # ---- symlinks ----------------------------------------------------------

    def link!(source, target, id, section, name, force)
      plugin_dir = Paths.plugin_dir(id)
      FileUtils.mkdir_p(File.dirname(target))

      if own_link?(target, plugin_dir)
        return # already linked by us
      elsif File.symlink?(target) || File.exist?(target)
        unless force
          raise Error,
                "#{target} already exists and is not a tallmadge link for #{id} " \
                "(use --force to back it up and replace)"
        end

        backup_existing(target, section, name)
      end

      File.symlink(source, target)
      Reporter.ok "linked #{target} → #{source}"
    end

    # Removes target only when it is a symlink resolving into this plugin's
    # store dir. Returns true when removed.
    def unlink!(target, id, section, name)
      plugin_dir = Paths.plugin_dir(id)
      if File.symlink?(target)
        unless own_link?(target, plugin_dir)
          Reporter.warn "#{target} is not a tallmadge link for #{id}, left in place"
          return false
        end

        File.delete(target)
        cleanup_empty_parents(target)
        Reporter.ok "unlinked #{target}"
        true
      elsif File.exist?(target)
        Reporter.warn "#{target} is not a tallmadge link, left in place"
        false
      else
        false
      end
    end

    def own_link?(target, plugin_dir)
      return false unless File.symlink?(target)

      real = File.realpath(target) rescue nil
      base = File.realpath(plugin_dir) rescue nil
      return false unless real && base

      real == base || real.start_with?(base + File::SEPARATOR)
    end

    def backup_existing(target, section, name)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      backup = File.join(Paths.backups_dir, "#{stamp}-#{section}-#{File.basename(name.to_s)}")
      FileUtils.mkdir_p(Paths.backups_dir)
      FileUtils.mv(target, backup)
      Reporter.warn "backed up existing #{target} → #{backup}"
    end

    def cleanup_empty_parents(target)
      dir = File.dirname(target)
      return unless Dir.exist?(dir) && Dir.children(dir).empty?

      section_dirs = Paths::SECTIONS.map do |s|
        File.realpath(Paths.agents_section(s)) rescue nil
      end
      real_dir = File.realpath(dir) rescue nil
      return if section_dirs.include?(real_dir)

      FileUtils.rmdir(dir)
    rescue Errno::ENOTEMPTY, Errno::ENOENT
      nil
    end

    # ---- component addressing ----------------------------------------------

    def plugin_entry(id)
      entry = @state.plugins[id]
      raise Error, "unknown plugin '#{id}' (installed: #{@state.plugins.keys.join(', ')})" unless entry

      entry
    end

    def selection(entry, only)
      components = entry["components"] || {}
      return all_pairs(components) unless only

      only.map do |section, name|
        validate_pair!(components, section, name)
        [section, name]
      end
    end

    def all_pairs(components)
      pairs = []
      components.each do |section, items|
        next if items.nil?

        if section == "agentsMd"
          pairs << ["agentsMd", nil]
          next
        end
        items.each_key { |name| pairs << [section, name] }
      end
      pairs
    end

    def validate_pair!(components, section, name)
      if section == "agentsMd"
        raise Error, "plugin has no agents.md component" unless components["agentsMd"]

        return
      end

      items = components[section]
      if items.nil? || !items.key?(name)
        available = items ? items.keys.join(", ") : "none"
        raise Error, "no #{section} component '#{name}' (available: #{available})"
      end
    end

    def component_info(entry, section, name)
      components = entry["components"] || {}
      section == "agentsMd" ? components["agentsMd"] : (components[section] || {})[name]
    end

    def mark_active(entry, section, name, active)
      info = component_info(entry, section, name)
      raise Error, "no #{section} component '#{name}'" unless info

      info["active"] = active
    end

    # Store-side source of a component.
    def component_source(id, section, name)
      dir = Paths.plugin_dir(id)
      case section
      when "skills"
        sub = File.join(dir, "skills", name)
        Dir.exist?(sub) ? sub : dir # root SKILL.md -> whole plugin dir
      when "agents"
        sub = File.join(dir, "agents", name)
        return sub if Dir.exist?(sub)

        agents_dir = File.join(dir, "agents")
        unless Dir.exist?(agents_dir)
          raise Error, "store dir for plugin #{id} has no agents/ (store missing?)"
        end

        flat = Dir.children(agents_dir).find do |f|
          File.file?(File.join(agents_dir, f)) &&
            File.basename(f, File.extname(f)) == name
        end
        unless flat
          raise Error, "no agent source for #{name} in plugin #{id}"
        end

        File.join(agents_dir, flat)
      when "tasks" then File.join(dir, "tasks", name)
      when "memories" then File.join(dir, "memories", name)
      else raise Error, "cannot link #{section} components"
      end
    end

    # Target path under ~/.agents. A flat agent file lands inside a
    # directory so the protocol shape agents/<name>/agent.md holds; memory
    # files link directly.
    def component_target(section, name, source)
      base = File.join(Paths.agents_section(section), name)
      if section == "agents" && !File.directory?(source)
        File.join(base, "agent.md")
      else
        base
      end
    end

    # ---- composers -----------------------------------------------------------

    def compose_agents_md!
      target = File.join(Paths.agents_home, "agents.md")
      user_fragment = read_user_content("agentsMd")
      fragments = active_agents_md_fragments

      if user_fragment.nil? && fragments.empty?
        if @state.composed["agentsMd"] && File.exist?(target) && agents_md_managed?(target)
          File.delete(target)
          Reporter.info "removed composed agents.md (no active content left)"
        end
        @state.composed["agentsMd"] = false
        return
      end

      adopt_agents_md!(target) if File.exist?(target) && !agents_md_managed?(target)
      # Adoption may have added a user fragment.
      user_fragment ||= read_user_content("agentsMd")

      lines = [AGENTS_MD_MARKER, ""]
      if user_fragment && !user_fragment.strip.empty?
        lines << user_fragment.strip << ""
      end
      fragments.each do |plugin_id, content|
        lines << "<!-- tallmadge:begin #{plugin_id} -->"
        lines << content.strip
        lines << "<!-- tallmadge:end #{plugin_id} -->"
        lines << ""
      end

      write_atomic(target, lines.join("\n").rstrip + "\n")
      @state.composed["agentsMd"] = true
      Reporter.ok "composed #{target} (#{fragments.size} plugin fragment#{fragments.size == 1 ? '' : 's'})"
    end

    def compose_mcp_json!
      target = File.join(Paths.agents_home, "mcp.json")
      adopt_mcp_json!(target) if File.exist?(target) && !@state.composed["mcpJson"]

      servers = {}
      origins = {}

      user_servers.each do |name, config|
        servers[name] = config
        origins[name] = "user"
      end

      @state.plugins.each do |id, entry|
        info = (entry["components"] || {})["mcpServers"]
        next if info.nil? || info.empty?

        plugin_servers = plugin_mcp_servers(id)
        info.each_key do |server_name|
          next unless info[server_name]["active"]

          config = plugin_servers[server_name]
          next unless config

          if servers.key?(server_name)
            Reporter.warn "mcp server '#{server_name}' already provided by " \
                          "#{origins[server_name]}, keeping first"
            next
          end
          servers[server_name] = config
          origins[server_name] = id
        end
      end

      if servers.empty?
        if @state.composed["mcpJson"] && File.exist?(target)
          File.delete(target)
          Reporter.info "removed composed mcp.json (no active servers left)"
        end
        @state.composed["mcpJson"] = false
        @state.mcp_origins.clear
        return
      end

      write_atomic(target, JSON.pretty_generate({ "mcpServers" => servers }) + "\n")
      @state.composed["mcpJson"] = true
      @state.data["mcpOrigins"] = origins
      Reporter.ok "composed #{target} (#{servers.size} server#{servers.size == 1 ? '' : 's'})"
    end

    def agents_md_managed?(target)
      File.open(target, &:readline).strip == AGENTS_MD_MARKER
    rescue EOFError
      false
    end

    def adopt_agents_md!(target)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      backup = File.join(Paths.backups_dir, "#{stamp}-agentsMd-agents.md")
      user_copy = File.join(Paths.user_store_dir, "agents.md")
      FileUtils.mkdir_p(Paths.backups_dir)
      FileUtils.mkdir_p(Paths.user_store_dir)
      FileUtils.cp(target, user_copy)
      FileUtils.mv(target, backup)
      @state.user_content["agentsMd"] = "store/user/agents.md"
      Reporter.warn "adopted existing #{target} (backup: #{backup}, user fragment: #{user_copy})"
    end

    def adopt_mcp_json!(target)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      backup = File.join(Paths.backups_dir, "#{stamp}-mcpJson-mcp.json")
      user_copy = File.join(Paths.user_store_dir, "mcp.json")
      FileUtils.mkdir_p(Paths.backups_dir)
      FileUtils.mkdir_p(Paths.user_store_dir)
      FileUtils.cp(target, user_copy)
      FileUtils.mv(target, backup)
      @state.user_content["mcpJson"] = "store/user/mcp.json"
      Reporter.warn "adopted existing #{target} (backup: #{backup}, user copy: #{user_copy})"
    end

    def read_user_content(key)
      rel = @state.user_content[key]
      return nil unless rel

      path = File.join(Paths.tallmadge_home, rel)
      File.exist?(path) ? File.read(path) : nil
    end

    def user_servers
      rel = @state.user_content["mcpJson"]
      return {} unless rel

      path = File.join(Paths.tallmadge_home, rel)
      return {} unless File.exist?(path)

      data = JSON.parse(File.read(path)) rescue {}
      servers = data["mcpServers"]
      servers.is_a?(Hash) ? servers : {}
    end

    def active_agents_md_fragments
      fragments = []
      @state.plugins.each do |id, entry|
        info = (entry["components"] || {})["agentsMd"]
        next unless info && info["active"]

        path = plugin_agents_md_path(id)
        next unless path

        fragments << [id, File.read(path)]
      end
      fragments
    end

    def plugin_agents_md_path(id)
      dir = Paths.plugin_dir(id)
      entry = Dir.children(dir).find do |f|
        f.casecmp?("agents.md") && File.file?(File.join(dir, f))
      end
      entry && File.join(dir, entry)
    end

    def plugin_mcp_servers(id)
      dir = Paths.plugin_dir(id)
      file = %w[mcp.json .mcp.json].map { |f| File.join(dir, f) }
                                    .find { |f| File.file?(f) }
      return {} unless file

      data = JSON.parse(File.read(file)) rescue {}
      servers = data["mcpServers"]
      servers.is_a?(Hash) ? servers : {}
    end

    def write_atomic(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}"
      File.write(tmp, content)
      File.rename(tmp, path)
    end

    def maintain_harnesses
      Harness.maintain!(@state) if defined?(Tallmadge::Harness)
    end
  end
end
