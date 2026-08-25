# frozen_string_literal: true

module Tallmadge
  # The activation engine. Activating a component symlinks its store copy
  # into the matching ~/.agents section; agents.md and mcp.json are composed
  # files, never symlinked. Every activate/deactivate recomposes both files
  # (via Composer) and lets Harness.maintain! refresh gap-bridging links.
  class Activator
    AGENTS_MD_MARKER = Composer::AGENTS_MD_MARKER
    LINK_SECTIONS = %w[skills agents tasks memories].freeze

    attr_reader :state, :composer

    def initialize(state)
      @state = state
      @composer = Composer.new(state)
    end

    # only: nil (all components) or an array of [section, name] pairs;
    # agentsMd is ["agentsMd", nil].
    def activate(id, only: nil, force: false)
      plugin_entry(id)
      entry = @state.ensure_profile_plugin!(id)
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
      plugin_entry(id)
      entry = @state.profile_plugins[id]
      if entry.nil? || !has_active_components?(entry)
        Reporter.warn "#{id}: nothing active in profile '#{@state.active_profile_name}'"
        return
      end

      pairs = selection(entry, only)
      pairs.each do |section, name|
        info = component_info(entry, section, name)
        next unless info && info["active"]

        mark_active(entry, section, name, false)
        next if section == "agentsMd" || section == "mcpServers"

        source = component_source(id, section, name)
        target = component_target(section, name, source)
        unlink!(target, id, section, name)
      end

      @state.save
      compose_agents_md!
      compose_mcp_json!
      @state.save
      maintain_harnesses
      Reporter.ok "deactivated #{Reporter.name(id)}"
    end

    def teardown_profile!
      @state.profile_plugins.each_key { |id| unlink_active_components!(id) }
      Harness.teardown_links!(@state) if defined?(Tallmadge::Harness)
      remove_composed_files!
      @state.save
    end

    def apply_profile!
      @state.profile_plugins.each do |id, entry|
        components = entry["components"] || {}
        all_pairs(components).each do |section, name|
          info = component_info(entry, section, name)
          next unless info && info["active"]
          next if section == "agentsMd" || section == "mcpServers"

          source = component_source(id, section, name)
          target = component_target(section, name, source)
          begin
            link!(source, target, id, section, name, false)
          rescue Tallmadge::Error => e
            Reporter.warn "skipping #{target}: #{e.message}"
            info["active"] = false
          end
        end
      end

      compose_agents_md!
      compose_mcp_json!
      @state.save
      maintain_harnesses
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

    # ---- composers (delegated to Composer) ----------------------------------

    def compose_agents_md!
      @composer.compose_agents_md!
    end

    def compose_mcp_json!
      @composer.compose_mcp_json!
    end

    def remove_composed_files!
      @composer.remove_composed_files!
    end

    def maintain_harnesses
      Harness.maintain!(@state) if defined?(Tallmadge::Harness)
    end

    def unlink_active_components!(id)
      entry = @state.profile_plugins[id]
      return 0 unless entry

      components = entry["components"] || {}
      count = 0
      all_pairs(components).each do |section, name|
        info = component_info(entry, section, name)
        next unless info && info["active"]
        next if section == "agentsMd" || section == "mcpServers"

        source = component_source(id, section, name)
        target = component_target(section, name, source)
        count += 1 if unlink!(target, id, section, name)
      end
      count
    end

    private

    def has_active_components?(entry)
      components = entry["components"] || {}
      components.any? do |section, items|
        if section == "agentsMd"
          items.is_a?(Hash) && items["active"]
        elsif items.is_a?(Hash)
          items.values.any? { |info| info.is_a?(Hash) && info["active"] }
        else
          false
        end
      end
    end

    def deactivate_components!(id)
      entry = @state.profile_plugins[id]
      return 0 unless entry

      components = entry["components"] || {}
      count = 0
      all_pairs(components).each do |section, name|
        info = component_info(entry, section, name)
        next unless info && info["active"]

        mark_active(entry, section, name, false)
        next if section == "agentsMd" || section == "mcpServers"

        source = component_source(id, section, name)
        target = component_target(section, name, source)
        count += 1 if unlink!(target, id, section, name)
      end
      count
    end
  end
end
