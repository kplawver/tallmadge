# frozen_string_literal: true

module Tallmadge
  # Harness gap-bridging. Native .agents support (verified):
  #   omp: reads ~/.agents/AGENTS.md and ~/.agents/skills; subagents load
  #        from FLAT files ~/.omp/agent/agents/<name>.md; no tasks/memories/mcp.
  #   pi:  reads ~/.agents/skills globally; global context from
  #        ~/.pi/agent/AGENTS.md; no markdown subagent slot; no mcp.json.
  # clpr link only fills those gaps.
  module Harness
    ADAPTERS = {
      "omp" => { "home" => ".omp" },
      "pi" => { "home" => ".pi" }
    }.freeze

    module_function

    def harness_home(harness_id)
      File.join(Dir.home, ADAPTERS.fetch(harness_id)["home"])
    end

    def installed_harnesses
      ADAPTERS.keys.select { |id| Dir.exist?(harness_home(id)) }
    end

    def ensure_present!(harness_id)
      unless ADAPTERS.key?(harness_id)
        raise Error, "unknown harness '#{harness_id}' (supported: #{ADAPTERS.keys.join(', ')})"
      end

      home = harness_home(harness_id)
      unless Dir.exist?(home)
        raise Error, "harness #{harness_id} does not appear to be installed (missing #{home})"
      end
    end

    # ---- expected gap links ---------------------------------------------------

    def active_agents(state)
      names = []
      state.profile_plugins.each_value do |entry|
        agents = entry.dig("components", "agents") || {}
        agents.each { |name, info| names << name if info["active"] }
      end
      names.uniq
    end

    def expected_links(state, harness_id)
      case harness_id
      when "omp"
        active_agents(state).each_with_object({}) do |name, map|
          target = File.join(harness_home("omp"), "agent", "agents", "#{name}.md")
          source = File.join(Paths.agents_section("agents"), name, "agent.md")
          map[target] = source
        end
      when "pi"
        agents_md = File.join(Paths.agents_home, "agents.md")
        if File.exist?(agents_md)
          { File.join(harness_home("pi"), "agent", "AGENTS.md") => agents_md }
        else
          {}
        end
      else
        {}
      end
    end

    # ---- link / unlink / maintain ------------------------------------------------

    def link(state, harness_id = nil, force: false)
      targets = harness_id ? [harness_id] : installed_harnesses
      if targets.empty?
        raise Error, "no supported harness installed (looked for ~/.omp and ~/.pi)"
      end

      targets.each do |hid|
        ensure_present!(hid)
        report_slot_notes(state, hid)
        links = sync!(state, hid, force: force)
        Reporter.ok "#{hid}: #{links.size} bridge link#{links.size == 1 ? '' : 's'} in place"
      end
    end

    def report_slot_notes(state, harness_id)
      agent_count = active_agents(state).size
      return unless agent_count.positive?

      case harness_id
      when "pi"
        Reporter.info "pi has no subagent slot — #{agent_count} active agent(s) are not bridged"
      when "omp"
        Reporter.info "omp skills and agents.md are read natively; bridging #{agent_count} agent(s) as flat files"
      end
    end

    def unlink(state, harness_id)
      ensure_known!(harness_id)
      entry = state.harnesses[harness_id]
      unless entry
        raise Error, "harness #{harness_id} is not linked by tallmadge"
      end

      (entry["links"] || {}).each { |target, source| remove_recorded(target, source, true) }
      state.harnesses.delete(harness_id)
      state.save
      Reporter.ok "unlinked #{harness_id}"
    end

    def teardown_links!(state)
      state.harnesses.each_value do |entry|
        (entry["links"] || {}).each do |target, source|
          File.delete(target) if matches?(target, source)
        end
      end
    end

    def ensure_known!(harness_id)
      return if ADAPTERS.key?(harness_id)

      raise Error, "unknown harness '#{harness_id}' (supported: #{ADAPTERS.keys.join(', ')})"
    end

    # Called by the Activator after every activate/deactivate: refresh links
    # for harnesses that were previously linked. Silent on conflicts.
    def maintain!(state)
      state.harnesses.each_key do |harness_id|
        next unless ADAPTERS.key?(harness_id)
        next unless Dir.exist?(harness_home(harness_id))

        sync!(state, harness_id, force: false, report: false)
      end
    end

    # Brings recorded links in line with expected links. Returns the links
    # actually in place.
    def sync!(state, harness_id, force: false, report: true)
      entry = state.harnesses[harness_id] ||= {
        "linkedAt" => Time.now.utc.iso8601, "links" => {}
      }
      recorded = entry["links"] || {}
      expected = expected_links(state, harness_id)

      (recorded.keys - expected.keys).each do |target|
        remove_recorded(target, recorded[target], report)
      end

      expected.each do |target, source|
        next if matches?(target, source)

        if File.symlink?(target) || File.exist?(target)
          if force
            backup_target(target, harness_id)
          else
            Reporter.warn "skipping #{target}: already exists (use --force to back it up and replace)" if report
            next
          end
        end

        unless File.exist?(source)
          Reporter.warn "skipping #{target}: source #{source} is missing" if report
          next
        end

        FileUtils.mkdir_p(File.dirname(target))
        File.symlink(source, target)
        Reporter.ok "linked #{target} → #{source}" if report
      end

      entry["links"] = expected.select { |target, source| matches?(target, source) }
      entry["linkedAt"] ||= Time.now.utc.iso8601
      state.save
      entry["links"]
    end

    def remove_recorded(target, source, report)
      if matches?(target, source)
        File.delete(target)
        Reporter.ok "removed #{target}" if report
      elsif File.exist?(target) || File.symlink?(target)
        Reporter.warn "#{target} changed since tallmadge linked it; left in place" if report
      end
    end

    # True when target is a symlink whose literal target is exactly source.
    # readlink (not realpath) so it still matches when the chain dangles
    # after the underlying component is deactivated.
    def matches?(target, source)
      return false unless File.symlink?(target)

      File.readlink(target) == source
    end

    def backup_target(target, harness_id)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      backup = File.join(Paths.backups_dir, "#{stamp}-#{harness_id}-#{File.basename(target)}")
      FileUtils.mkdir_p(Paths.backups_dir)
      FileUtils.mv(target, backup)
      Reporter.warn "backed up existing #{target} → #{backup}"
    end

    # ---- doctor --------------------------------------------------------------------

    # Prints a health report; returns the number of errors found.
    def doctor(state)
      errors = 0
      Paths.ensure_skeleton!

      Reporter.info "== plugins =="
      if state.plugins.empty?
        Reporter.info "no plugins installed"
      else
        state.plugins.each_key do |id|
          if Dir.exist?(Paths.plugin_dir(id))
            Reporter.ok "plugin #{id}: store present"
          else
            Reporter.err "plugin #{id}: store dir missing — fix with: clpr uninstall #{id}"
            errors += 1
          end
        end
      end

      Reporter.info "== ~/.agents links =="
      errors += check_section_links(state)

      Reporter.info "== unmanaged content in ~/.agents =="
      list_unmanaged(state)

      Reporter.info "== harnesses =="
      errors += check_harness_links(state)
      report_native_support
      errors
    end

    # Symlinks in the four sections that point into the store but are not
    # accounted for by state are orphans.
    def check_section_links(state)
      errors = 0
      known = known_section_targets(state)
      store_base = File.realpath(Paths.store_dir) rescue nil

      Paths::SECTIONS.each do |section|
        dir = Paths.agents_section(section)
        next unless Dir.exist?(dir)

        Dir.children(dir).sort.each do |entry_name|
          path = File.join(dir, entry_name)
          next unless File.symlink?(path)

          real = File.realpath(path) rescue nil
          next unless store_base && real && real.start_with?(store_base + File::SEPARATOR)

          if known.include?(path)
            Reporter.ok "#{path}: managed link"
          else
            Reporter.warn "#{path}: points into the tallmadge store but is not in state (orphan)"
          end
        end
      end
      errors
    end

    def known_section_targets(state)
      activator = Activator.new(state)
      known = Set.new
      state.plugins.each_key do |id|
        entry = state.plugins[id]
        (entry["components"] || {}).each do |section, items|
          next unless Activator::LINK_SECTIONS.include?(section)

          items.each do |name, info|
            next unless info["active"]

            source = activator.component_source(id, section, name)
            known << activator.component_target(section, name, source)
          rescue Error
            next
          end
        end
      end
      known
    end

    def list_unmanaged(state)
      store_base = File.realpath(Paths.store_dir) rescue nil
      found = false

      Dir.children(Paths.agents_home).sort.each do |entry_name|
        path = File.join(Paths.agents_home, entry_name)
        if Paths::SECTIONS.include?(entry_name)
          Dir.children(path).sort.each do |child|
            child_path = File.join(path, child)
            next if tallmadge_link?(child_path, store_base)

            Reporter.info "#{child_path}: not managed by tallmadge"
            found = true
          end
        elsif entry_name.casecmp?("agents.md") || entry_name.casecmp?("mcp.json")
          if composed_by_tallmadge?(state, path, entry_name)
            Reporter.ok "#{path}: composed by tallmadge"
          else
            Reporter.info "#{path}: not managed by tallmadge"
            found = true
          end
        else
          Reporter.info "#{path}: not managed by tallmadge"
          found = true
        end
      end
      Reporter.info "all content managed by tallmadge" unless found
    end

    def tallmadge_link?(path, store_base)
      return false unless File.symlink?(path)

      real = File.realpath(path) rescue nil
      store_base && real && real.start_with?(store_base + File::SEPARATOR)
    end

    def composed_by_tallmadge?(state, path, entry_name)
      if entry_name.casecmp?("agents.md")
        first = File.open(path, &:readline).strip rescue ""
        first == Activator::AGENTS_MD_MARKER
      else
        state.composed["mcpJson"]
      end
    end

    def check_harness_links(state)
      errors = 0
      state.harnesses.each do |harness_id, entry|
        (entry["links"] || {}).each do |target, source|
          if matches?(target, source)
            Reporter.ok "#{harness_id}: #{target}"
          else
            Reporter.warn "#{harness_id}: recorded link #{target} is broken or missing"
            errors += 1
          end
        end
      end
      errors
    end

    def report_native_support
      omp_bridge = File.join(Dir.home, ".omp", "agent", "skills")
      if File.symlink?(omp_bridge)
        Reporter.info "~/.omp/agent/skills -> #{File.readlink(omp_bridge)}: native skills " \
                      "bridge already present, no action needed"
      end
      if Dir.exist?(harness_home("omp"))
        Reporter.info "omp: reads ~/.agents/AGENTS.md and ~/.agents/skills natively; " \
                      "subagents bridged as flat files in ~/.omp/agent/agents/; " \
                      "tasks/memories/mcp.json are not read by omp"
      end
      if Dir.exist?(harness_home("pi"))
        Reporter.info "pi: reads ~/.agents/skills natively; global context bridged via " \
                      "~/.pi/agent/AGENTS.md; pi has no subagent slot; mcp.json is not read by pi"
      end
    end
  end
end

