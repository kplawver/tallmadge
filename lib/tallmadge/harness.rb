# frozen_string_literal: true

module Tallmadge
  # Harness gap-bridging. Every adapter records what a harness already reads
  # out of ~/.agents ("native") and where its own global config lives
  # ("bridge"); clpr only symlinks the gaps. Facts below were verified
  # against each harness's docs or source in September 2026 — re-verify
  # before changing a path, and never guess one.
  #
  # Bridge kinds:
  #   instructions       single file fed by the composed ~/.agents/agents.md
  #   skills             directory that gets one symlink per active skill
  #   agents             subagent directory; "flat" links <name><suffix> to
  #                      agents/<name>/agent.md, "dir" links the whole
  #                      agents/<name> directory
  #   mcp                file fed by the composed ~/.agents/mcp.json
  #                      (only where the harness reads a dedicated
  #                      {"mcpServers": {...}} file)
  #   uppercaseAgentsMd  harness reads ~/.agents/AGENTS.md by exact name,
  #                      which the composed lowercase agents.md only
  #                      satisfies on a case-insensitive filesystem
  module Harness
    ADAPTERS = {
      "omp" => {
        "label" => "Oh My Pi",
        "detect" => [".omp"],
        "native" => %w[agentsMd skills],
        "bridge" => {
          "uppercaseAgentsMd" => true,
          "agents" => { "dir" => ".omp/agent/agents", "layout" => "flat" }
        },
        "notes" => ["tasks, memories, and mcp.json are not read by omp"]
      },
      "pi" => {
        "label" => "Pi",
        "detect" => [".pi"],
        "native" => %w[skills],
        "bridge" => { "instructions" => ".pi/agent/AGENTS.md" },
        "notes" => ["pi has no subagent slot; mcp.json is not read by pi"]
      },
      "cline" => {
        "label" => "Cline",
        "detect" => [".cline"],
        "env" => { "var" => "CLINE_DIR", "prefix" => ".cline" },
        "native" => %w[agentsMd skills],
        "bridge" => {
          "uppercaseAgentsMd" => true,
          "mcp" => ".cline/data/settings/cline_mcp_settings.json"
        },
        "notes" => [
          "subagents are YAML files in ~/.cline/agents — not bridged",
          "servers Cline adds itself land in the linked mcp.json and are " \
          "replaced on the next compose — manage them with clpr mcp add"
        ]
      },
      "kilo" => {
        "label" => "Kilo Code",
        "detect" => [".config/kilo", ".kilo"],
        "env" => { "var" => "XDG_CONFIG_HOME", "prefix" => ".config" },
        "native" => %w[skills],
        "bridge" => {
          "instructions" => ".config/kilo/AGENTS.md",
          "agents" => { "dir" => ".config/kilo/agent", "layout" => "flat" }
        },
        "notes" => ["MCP servers live under the mcp key of kilo.jsonc — not bridged"]
      },
      "amp" => {
        "label" => "Amp",
        "detect" => [".config/amp"],
        "env" => { "var" => "XDG_CONFIG_HOME", "prefix" => ".config" },
        "native" => %w[skills],
        "bridge" => { "instructions" => ".config/amp/AGENTS.md" },
        "notes" => [
          "custom agents are TypeScript plugins — not bridged",
          "MCP servers live under amp.mcpServers in settings.json — not bridged"
        ]
      },
      "devin" => {
        "label" => "Devin CLI",
        "detect" => [".config/devin"],
        "env" => { "var" => "XDG_CONFIG_HOME", "prefix" => ".config" },
        "native" => %w[skills],
        "bridge" => {
          "instructions" => ".config/devin/AGENTS.md",
          "agents" => { "dir" => ".config/devin/agents", "layout" => "dir" },
          "mcp" => ".config/devin/mcp_config.json"
        },
        "notes" => [
          "cloud Devin reads repo files only; this bridges the Devin CLI",
          "devin mcp add -s user writes the linked mcp.json and clpr " \
          "replaces those servers on the next compose — use clpr mcp add"
        ]
      },
      "claude" => {
        "label" => "Claude Code",
        "detect" => [".claude"],
        "env" => { "var" => "CLAUDE_CONFIG_DIR", "prefix" => ".claude" },
        "native" => [],
        "bridge" => {
          "instructions" => ".claude/CLAUDE.md",
          "skills" => ".claude/skills",
          "agents" => { "dir" => ".claude/agents", "layout" => "flat" }
        },
        "notes" => ["user MCP servers share ~/.claude.json with app state — not bridged"]
      },
      "codex" => {
        "label" => "Codex CLI",
        "detect" => [".codex"],
        "env" => { "var" => "CODEX_HOME", "prefix" => ".codex" },
        "native" => %w[skills],
        "bridge" => { "instructions" => ".codex/AGENTS.md" },
        "notes" => ["subagents and MCP servers are TOML (~/.codex) — not bridged"]
      },
      "opencode" => {
        "label" => "opencode",
        "detect" => [".config/opencode"],
        "env" => { "var" => "XDG_CONFIG_HOME", "prefix" => ".config" },
        "native" => %w[skills],
        "bridge" => {
          "instructions" => ".config/opencode/AGENTS.md",
          "agents" => { "dir" => ".config/opencode/agent", "layout" => "flat" }
        },
        "notes" => ["MCP servers live under the mcp key of opencode.json — not bridged"]
      },
      "gemini" => {
        "label" => "Gemini CLI",
        "detect" => [".gemini"],
        "native" => %w[skills],
        "bridge" => {
          "instructions" => ".gemini/GEMINI.md",
          "agents" => { "dir" => ".gemini/agents", "layout" => "flat" }
        },
        "notes" => ["MCP servers live under mcpServers in settings.json — not bridged"]
      },
      "cursor" => {
        "label" => "Cursor CLI",
        "detect" => [".cursor"],
        "env" => { "var" => "CURSOR_CONFIG_DIR", "prefix" => ".cursor" },
        "native" => %w[skills],
        "bridge" => {
          "agents" => { "dir" => ".cursor/agents", "layout" => "flat" },
          "mcp" => ".cursor/mcp.json"
        },
        "notes" => ["user rules live in Cursor's settings UI, not a file — agents.md is not bridged"]
      },
      "copilot" => {
        "label" => "GitHub Copilot CLI",
        "detect" => [".copilot"],
        "env" => { "var" => "COPILOT_HOME", "prefix" => ".copilot" },
        "native" => %w[skills],
        "bridge" => {
          "instructions" => ".copilot/copilot-instructions.md",
          "agents" => { "dir" => ".copilot/agents", "layout" => "flat", "suffix" => ".agent.md" },
          "mcp" => ".copilot/mcp-config.json"
        }
      }
    }.freeze

    NATIVE_LABELS = { "agentsMd" => "agents.md", "skills" => "skills" }.freeze

    module_function

    def adapter(harness_id)
      ADAPTERS.fetch(harness_id)
    end

    # Adapter paths are written relative to ~; a harness that relocates its
    # whole config tree through an environment variable re-roots the part of
    # the path that variable owns.
    def harness_path(harness_id, rel)
      env = adapter(harness_id)["env"]
      root = env && ENV[env["var"]]
      return File.join(Dir.home, rel) if root.nil? || root.empty?

      prefix = env["prefix"]
      return File.expand_path(root) if rel == prefix

      if rel.start_with?(prefix + File::SEPARATOR)
        return File.join(File.expand_path(root), rel.delete_prefix(prefix + File::SEPARATOR))
      end

      File.join(Dir.home, rel)
    end

    def harness_homes(harness_id)
      adapter(harness_id)["detect"].map { |rel| harness_path(harness_id, rel) }
    end

    def harness_home(harness_id)
      homes = harness_homes(harness_id)
      homes.find { |dir| Dir.exist?(dir) } || homes.first
    end

    def installed?(harness_id)
      harness_homes(harness_id).any? { |dir| Dir.exist?(dir) }
    end

    def installed_harnesses
      ADAPTERS.keys.select { |id| installed?(id) }
    end

    def ensure_present!(harness_id)
      ensure_known!(harness_id)
      return if installed?(harness_id)

      raise Error, "harness #{harness_id} does not appear to be installed " \
                   "(missing #{harness_homes(harness_id).join(', ')})"
    end

    def ensure_known!(harness_id)
      return if ADAPTERS.key?(harness_id)

      raise Error, "unknown harness '#{harness_id}' (supported: #{ADAPTERS.keys.join(', ')})"
    end

    # ---- expected gap links ---------------------------------------------------

    def active_components(state, section)
      names = []
      state.profile_plugins.each_value do |entry|
        (entry.dig("components", section) || {}).each do |name, info|
          names << name if info["active"]
        end
      end
      names.uniq
    end

    def active_agents(state)
      active_components(state, "agents")
    end

    def agents_md_path
      File.join(Paths.agents_home, "agents.md")
    end

    def mcp_json_path
      File.join(Paths.agents_home, "mcp.json")
    end

    # Harnesses that read ~/.agents/AGENTS.md match the name byte for byte,
    # so the composed lowercase agents.md is invisible to them on a
    # case-sensitive filesystem. Probe the skeleton's skills/ directory
    # under a spelling clpr never creates: if SKILLS resolves too, the
    # filesystem folds case and the alias would be pointless.
    def case_sensitive_agents_home?
      skills = Paths.agents_section("skills")
      return false unless Dir.exist?(skills)

      !Dir.exist?(File.join(Paths.agents_home, "SKILLS"))
    end

    def expected_links(state, harness_id)
      bridge = adapter(harness_id)["bridge"] || {}
      links = {}
      agents_md = agents_md_path

      if File.exist?(agents_md)
        rel = bridge["instructions"]
        links[harness_path(harness_id, rel)] = agents_md if rel
        if bridge["uppercaseAgentsMd"] && case_sensitive_agents_home?
          links[File.join(Paths.agents_home, "AGENTS.md")] = agents_md
        end
      end

      if (rel = bridge["mcp"]) && File.exist?(mcp_json_path)
        links[harness_path(harness_id, rel)] = mcp_json_path
      end

      if (rel = bridge["skills"])
        dir = harness_path(harness_id, rel)
        active_components(state, "skills").each do |name|
          links[File.join(dir, name)] = File.join(Paths.agents_section("skills"), name)
        end
      end

      if (spec = bridge["agents"])
        dir = harness_path(harness_id, spec["dir"])
        flat = spec["layout"] == "flat"
        suffix = spec["suffix"] || ".md"
        active_agents(state).each do |name|
          source = File.join(Paths.agents_section("agents"), name)
          if flat
            links[File.join(dir, "#{name}#{suffix}")] = File.join(source, "agent.md")
          else
            links[File.join(dir, name)] = source
          end
        end
      end

      links
    end

    # ---- link / unlink / maintain ------------------------------------------------

    def link(state, harness_id = nil, force: false)
      targets = harness_id ? [harness_id] : installed_harnesses
      if targets.empty?
        looked = ADAPTERS.keys.flat_map { |id| harness_homes(id) }.uniq
        raise Error, "no supported harness installed (looked for #{looked.join(', ')})"
      end

      targets.each do |hid|
        ensure_present!(hid)
        report_slot_notes(state, hid)
        links = sync!(state, hid, force: force)
        Reporter.ok "#{hid}: #{links.size} bridge link#{links.size == 1 ? '' : 's'} in place"
      end
    end

    def report_slot_notes(state, harness_id)
      entry = adapter(harness_id)
      native = (entry["native"] || []).map { |slot| NATIVE_LABELS[slot] }.compact
      Reporter.info "#{harness_id}: reads #{native.join(' and ')} from ~/.agents natively" if native.any?

      bridge = entry["bridge"] || {}
      agent_count = active_agents(state).size
      if agent_count.positive? && bridge["agents"].nil?
        Reporter.info "#{harness_id}: no markdown subagent slot — " \
                      "#{agent_count} active agent(s) are not bridged"
      end

      (entry["notes"] || []).each { |note| Reporter.info "#{harness_id}: #{note}" }
    end

    def unlink(state, harness_id)
      ensure_known!(harness_id)
      entry = state.harnesses[harness_id]
      unless entry
        raise Error, "harness #{harness_id} is not linked by tallmadge"
      end

      keep = shared_targets(state, harness_id)
      (entry["links"] || {}).each do |target, source|
        next if keep.include?(target)

        remove_recorded(target, source, true)
      end
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

    # Targets another linked harness still expects, so tearing one bridge
    # down never removes a link a sibling harness depends on (the shared
    # ~/.agents/AGENTS.md alias, for instance).
    def shared_targets(state, harness_id)
      state.harnesses.keys.each_with_object(Set.new) do |other, set|
        next if other == harness_id
        next unless ADAPTERS.key?(other)

        set.merge(expected_links(state, other).keys)
      end
    end

    # Called by the Activator after every activate/deactivate: refresh links
    # for harnesses that were previously linked. Silent on conflicts.
    def maintain!(state)
      state.harnesses.each_key do |harness_id|
        next unless ADAPTERS.key?(harness_id)
        next unless installed?(harness_id)

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
      keep = shared_targets(state, harness_id)

      (recorded.keys - expected.keys).each do |target|
        next if keep.include?(target)

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

    # `active` lives on profile plugin entries, not the global plugin
    # records, so resolve known targets from state.profile_plugins.
    def known_section_targets(state)
      activator = Activator.new(state)
      known = Set.new
      state.profile_plugins.each do |id, entry|
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
        next if Paths::IGNORED_ENTRIES.include?(entry_name)

        path = File.join(Paths.agents_home, entry_name)
        if Paths::SECTIONS.include?(entry_name)
          Dir.children(path).sort.each do |child|
            next if Paths::IGNORED_ENTRIES.include?(child)

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

    # One line per detected harness: what it reads from ~/.agents by itself,
    # what clpr can bridge, and what no symlink can reach.
    def report_native_support
      detected = installed_harnesses
      if detected.empty?
        Reporter.info "no supported harness detected"
        return
      end

      detected.each do |id|
        entry = adapter(id)
        native = (entry["native"] || []).map { |slot| NATIVE_LABELS[slot] }.compact
        bridged = bridged_slots(id)
        Reporter.info "#{id} (#{entry['label']}): " \
                      "native #{native.empty? ? 'nothing' : native.join(', ')}; " \
                      "bridged #{bridged.empty? ? 'nothing' : bridged.join(', ')}"
        (entry["notes"] || []).each { |note| Reporter.info "  #{note}" }
      end
    end

    def bridged_slots(harness_id)
      bridge = adapter(harness_id)["bridge"] || {}
      slots = []
      slots << "agents.md" if bridge["instructions"]
      slots << "AGENTS.md casing" if bridge["uppercaseAgentsMd"]
      slots << "skills" if bridge["skills"]
      slots << "agents" if bridge["agents"]
      slots << "mcp.json" if bridge["mcp"]
      slots
    end
  end
end
