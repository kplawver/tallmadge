# frozen_string_literal: true

require "pathname"

module Tallmadge
  # Repo-level agent-file auditing and symlink bridging. Tallmadge never
  # manages repo content itself: `check` reports issues in a repo's
  # agent-related files (like Harness.doctor does for home) and `link`
  # bridges the canonical `.agents/` layout into each harness's repo-level
  # config directory. Nothing is ever deleted or overwritten.
  #
  # Everything here is a pure function of the repo directory: no State is
  # loaded and `~/.agents` is never read, so the commands are safe to run
  # in CI against any clone.
  #
  # Bridge facts below were verified against each harness's docs or source
  # in September 2026 — re-verify before changing a path, and never guess
  # one.
  module Repo
    # One entry per harness id; all paths relative to the repo root.
    # instructions: harness-specific alias file that links to AGENTS.md
    # skills:      whole-dir link target for .agents/skills (nil = native)
    # agents:      link spec for .agents/agents — "dir" links the whole
    #              directory, "copilot" makes per-agent flat files
    #              (nil = native or not bridgeable; see INFO_NOTES)
    REPO_BRIDGES = {
      "claude" => {
        "detect" => ".claude",
        "instructions" => "CLAUDE.md",
        "skills" => ".claude/skills",
        "agents" => { "layout" => "dir", "dir" => ".claude/agents" }
      },
      "cursor" => {
        "detect" => ".cursor",
        "instructions" => nil,
        "skills" => nil,
        "agents" => { "layout" => "dir", "dir" => ".cursor/agents" }
      },
      "cline" => {
        "detect" => ".cline",
        "instructions" => nil,
        "skills" => ".cline/skills",
        "agents" => nil
      },
      "gemini" => {
        "detect" => ".gemini",
        "instructions" => "GEMINI.md",
        "skills" => nil,
        "agents" => { "layout" => "dir", "dir" => ".gemini/agents" }
      },
      "kilo" => {
        "detect" => ".kilo",
        "instructions" => nil,
        "skills" => nil,
        "agents" => { "layout" => "dir", "dir" => ".kilo/agents" }
      },
      "opencode" => {
        "detect" => ".opencode",
        "instructions" => nil,
        "skills" => nil,
        "agents" => { "layout" => "dir", "dir" => ".opencode/agents" }
      },
      "copilot" => {
        "detect" => ".github/agents",
        "instructions" => nil,
        "skills" => nil,
        "agents" => { "layout" => "copilot", "dir" => ".github/agents" }
      },
      "omp" => {
        "detect" => ".omp",
        "instructions" => nil,
        "skills" => nil,
        "agents" => { "layout" => "dir", "dir" => ".omp/agents" }
      },
      "devin" => {
        "detect" => ".devin",
        "instructions" => nil,
        "skills" => nil,
        "agents" => nil
      },
      "pi" => {
        "detect" => ".pi",
        "instructions" => nil,
        "skills" => nil,
        "agents" => nil
      },
      "codex" => {
        "detect" => ".codex",
        "instructions" => nil,
        "skills" => nil,
        "agents" => nil
      },
      "amp" => {
        "detect" => ".amp",
        "instructions" => nil,
        "skills" => nil,
        "agents" => nil
      }
    }.freeze

    # Info lines for harnesses whose agents slot no symlink can reach.
    INFO_NOTES = {
      "codex" => "codex: agents are TOML in .codex/agents — maintain manually",
      "amp" => "amp: custom agents are TypeScript plugins — not bridgeable",
      "cline" => "cline: agents are YAML in .cline/agents — not bridgeable"
    }.freeze

    # File basename charset Copilot accepts for .github/agents entries.
    COPILOT_NAME_RE = /\A[.\-_a-zA-Z0-9]+\z/

    # A single bridge link check/plan wants to create. kind is
    # :instructions, :skills, or :agents; rel_target is the symlink text
    # (relative to the link's parent dir); status is :ok (already the
    # expected link), :missing, or :conflict (exists but is something
    # else — never touched by link).
    PlannedLink = Struct.new(:kind, :target, :source, :rel_target, :status)

    ERROR_CAP = 10

    module_function

    # Nearest ancestor of dir (inclusive) containing .git. Raises when
    # dir is not inside a git repository — repo-level bridging only makes
    # sense for repos whose committed links survive a clone.
    def find_root(dir)
      raise Error, "not a directory: #{dir}" unless Dir.exist?(dir)

      Pathname.new(File.expand_path(dir)).ascend do |path|
        return path.to_s if File.directory?(File.join(path, ".git"))
      end
      raise Error, "not a git repository: #{dir}"
    end

    # Harness ids whose repo-level detect directory exists.
    def detected(repo_root)
      REPO_BRIDGES.select { |_, b| Dir.exist?(File.join(repo_root, b["detect"])) }.keys
    end

    def canonical_instructions(repo_root)
      agents = File.join(repo_root, "AGENTS.md")
      if File.file?(agents) && !File.symlink?(agents)
        agents
      elsif File.symlink?(agents)
        target = File.expand_path(File.readlink(agents), repo_root)
        target if File.file?(target)
      end
    end

    # Every link the given harnesses need, in deterministic order:
    # instructions first, then skills, then agents. Links whose canonical
    # source is missing are not planned at all (check reports the content
    # gap separately). Never touches the filesystem.
    def plan(repo_root, harnesses)
      canonical = canonical_instructions(repo_root)
      links = []

      Array(harnesses).each do |id|
        bridge = REPO_BRIDGES.fetch(id) do
          raise Error, "unknown harness '#{id}' (supported: #{REPO_BRIDGES.keys.join(', ')})"
        end

        # Reverse-canonical (alias IS the canonical file): no alias link;
        # skills/agents bridges below still apply.
        alias_path = bridge["instructions"] && File.join(repo_root, bridge["instructions"])
        if canonical && alias_path && canonical != alias_path
          links << planned_link(:instructions, alias_path, canonical)
        end

        skills_dir = File.join(repo_root, ".agents", "skills")
        if bridge["skills"] && Dir.exist?(skills_dir)
          links << planned_link(:skills, File.join(repo_root, bridge["skills"]), skills_dir)
        end

        agents_dir = File.join(repo_root, ".agents", "agents")
        links.concat(plan_agents(repo_root, bridge["agents"], agents_dir)) if bridge["agents"]
      end

      links
    end

    def plan_agents(repo_root, spec, agents_dir)
      return [] unless Dir.exist?(agents_dir)

      if spec["layout"] == "copilot"
        plan_copilot_agents(repo_root, spec["dir"], agents_dir)
      else
        [planned_link(:agents, File.join(repo_root, spec["dir"]), agents_dir)]
      end
    end

    # Copilot requires one flat .agent.md file per agent; the canonical
    # directory (dir-per-agent with agent.md, or flat <name>.md) is linked
    # file by file instead of as a whole directory.
    def plan_copilot_agents(repo_root, target_dir, agents_dir)
      sources = Dir.children(agents_dir).sort.map do |name|
        if File.directory?(File.join(agents_dir, name))
          File.join(name, "agent.md")
        elsif name.end_with?(".md")
          name
        end
      end.compact

      sources.map do |rel|
        source = File.join(agents_dir, rel)
        name = rel.end_with?("/agent.md") ? File.dirname(rel) : File.basename(rel, ".md")
        if name !~ COPILOT_NAME_RE
          Reporter.warn "copilot: skipping agent '#{name}' — " \
                        "name must match #{COPILOT_NAME_RE.source} for .github/agents"
          next
        end
        planned_link(:agents, File.join(repo_root, target_dir, "#{name}.agent.md"), source)
      end.compact
    end

    def planned_link(kind, target, source)
      rel_target = Pathname.new(source).relative_path_from(Pathname.new(File.dirname(target))).to_s
      PlannedLink.new(kind, target, source, rel_target, link_status(target, rel_target))
    end

    def link_status(target, rel_target)
      return :ok if File.symlink?(target) && File.readlink(target) == rel_target
      return :conflict if File.exist?(target) || File.symlink?(target)

      :missing
    end

    # True when path is a symlink whose target doesn't exist (a committed
    # link whose destination is missing on this machine). Dir.exist?
    # returns false for these, so checks report them as absent.
    def dangling?(path)
      File.symlink?(path) && !File.exist?(path)
    end

    # Prints the audit report; returns the error count (check exits 1 on
    # any error, so it can gate CI).
    def check(dir)
      repo_root = find_root(dir)
      detected_ids = detected(repo_root)
      # plan() emits Copilot charset warnings, so call it once and share.
      links = plan(repo_root, detected_ids)
      errors = 0
      warnings = 0

      errors += check_instructions(repo_root, links.select { |l| l.kind == :instructions }) { |w| warnings += 1 if w }
      errors += check_canonical_content(repo_root) { |w| warnings += 1 if w }

      Reporter.info "== harness bridges =="
      if detected_ids.empty?
        Reporter.info "no supported harness detected in this repo"
      else
        links.reject { |link| link.kind == :instructions }.each do |link|
          harness = harness_for(repo_root, link)
          case link.status
          when :ok
            Reporter.ok "#{rel(repo_root, link.target)} → #{link.rel_target}"
          when :missing
            Reporter.warn "#{harness}: #{rel(repo_root, link.target)} missing " \
                          "(run: clpr repo link --execute)"
            warnings += 1
          when :conflict
            Reporter.err "#{harness}: #{rel(repo_root, link.target)} exists but is not " \
                         "the expected symlink — consolidate manually"
            errors += 1
          end
        end
        detected_ids.each { |id| Reporter.info INFO_NOTES[id] if INFO_NOTES[id] }
      end

      bridgeable = REPO_BRIDGES.filter_map do |id, b|
        id if b.values_at("instructions", "skills", "agents").any? && !detected_ids.include?(id)
      end
      unless bridgeable.empty?
        Reporter.info "not detected in this repo: #{bridgeable.join(', ')} " \
                      "(bridge with: clpr repo link --harness ID, or --all for every supported harness)"
      end

      if Gem.win_platform? && !links.empty?
        Reporter.info "committed symlinks need core.symlinks=true on Windows clones — " \
                      "they otherwise check out as text files"
      end

      Reporter.info "#{errors} error(s), #{warnings} warning(s)"
      errors
    end

    # Which harness a planned link belongs to, for report lines. Derived
    # from the target itself so check never has to thread harness context
    # through plan; instruction aliases live at the repo root, everything
    # else under the bridge dir.
    def harness_for(repo_root, link)
      rel_target = rel(repo_root, link.target)
      REPO_BRIDGES.find do |_, b|
        rel_target == b["instructions"] ||
          rel_target.start_with?("#{b['detect']}/")
      end&.first || "repo"
    end

    # Bridge instructions: resolve the canonical file first (a symlinked
    # AGENTS.md — the kaleidoscope pattern — is healthy, not an error),
    # then report each detected harness's alias link. The planned
    # :instructions links (already reverse-canonical-filtered by plan)
    # are the single source of truth, so this section reports each alias
    # exactly once.
    def check_instructions(repo_root, instruction_links)
      errors = 0
      Reporter.info "== instructions =="

      agents_md = File.join(repo_root, "AGENTS.md")
      canonical = canonical_instructions(repo_root)
      if canonical
        if canonical == agents_md
          Reporter.ok "AGENTS.md (canonical)"
        else
          Reporter.ok "#{rel(repo_root, agents_md)} → #{File.basename(canonical)} " \
                      "(canonical: #{File.basename(canonical)})"
        end
      else
        alias_present = %w[CLAUDE.md GEMINI.md].any? { |n| File.file?(File.join(repo_root, n)) }
        if dangling?(agents_md)
          Reporter.err "#{rel(repo_root, agents_md)} is a broken symlink (points at " \
                       "#{File.readlink(agents_md)}) — fix or remove it"
          errors += 1
        elsif alias_present
          Reporter.warn "AGENTS.md missing — some harnesses read it natively; " \
                        "symlink it to your instructions file"
          yield true
        else
          Reporter.err "no AGENTS.md — create one so every harness sees your standards"
          errors += 1
        end
      end

      instruction_links.each do |link|
        alias_name = File.basename(link.target)
        label = harness_for(repo_root, link) == "gemini" ? "Gemini CLI" : "Claude Code"
        case link.status
        when :ok
          Reporter.ok "#{alias_name} → #{link.rel_target}"
        when :missing
          Reporter.warn "#{alias_name} missing — #{label} users see no project instructions"
          yield true
        when :conflict
          Reporter.err "#{alias_name} exists but is not a symlink to " \
                       "#{File.basename(link.source)} — consolidate manually"
          errors += 1
        end
      end

      errors
    end

    def check_canonical_content(repo_root)
      errors = 0
      Reporter.info "== canonical content =="

      skills_dir = File.join(repo_root, ".agents", "skills")
      agents_dir = File.join(repo_root, ".agents", "agents")
      if Dir.exist?(skills_dir)
        errors += check_skill_frontmatter(skills_dir)
      elsif dangling?(skills_dir)
        Reporter.err ".agents/skills is a broken symlink (points at #{File.readlink(skills_dir)}) — " \
                     "fix or remove it"
        errors += 1
      else
        Reporter.warn "no .agents/skills directory"
        yield true
      end
      if Dir.exist?(agents_dir)
        errors += check_agent_frontmatter(agents_dir)
      elsif dangling?(agents_dir)
        Reporter.err ".agents/agents is a broken symlink (points at #{File.readlink(agents_dir)}) — " \
                     "fix or remove it"
        errors += 1
      else
        Reporter.warn "no .agents/agents directory"
        yield true
      end

      errors
    end

    def check_skill_frontmatter(skills_dir)
      msgs = Dir.children(skills_dir).sort.each_with_object([]) do |name, acc|
        skill_md = File.join(skills_dir, name, "SKILL.md")
        next unless File.file?(skill_md)

        fm, = Frontmatter.parse(File.read(skill_md))
        acc << "#{rel(skills_dir, skill_md)}: missing description frontmatter — " \
               "required by most harnesses" if fm["description"].to_s.strip.empty?
      end
      report_frontmatter_errors(msgs)
    end

    def check_agent_frontmatter(agents_dir)
      msgs = []
      Dir.children(agents_dir).sort.each do |name|
        paths = agent_file_paths(agents_dir, name)
        paths.each do |path|
          next unless File.file?(path)

          fm, = Frontmatter.parse(File.read(path))
          msgs << "#{rel(agents_dir, path)}: missing name frontmatter" if fm["name"].to_s.strip.empty?
          msgs << "#{rel(agents_dir, path)}: missing description frontmatter" if fm["description"].to_s.strip.empty?
        end
      end
      report_frontmatter_errors(msgs.sort)
    end

    def agent_file_paths(agents_dir, name)
      if File.directory?(File.join(agents_dir, name))
        [File.join(agents_dir, name, "agent.md")]
      elsif name.end_with?(".md")
        [File.join(agents_dir, name)]
      else
        []
      end
    end

    def report_frontmatter_errors(msgs)
      msgs.first(ERROR_CAP).each { |msg| Reporter.err msg }
      Reporter.err "…and #{msgs.size - ERROR_CAP} more" if msgs.size > ERROR_CAP
      msgs.size
    end

    def rel(root, path)
      Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
    end

    # Show (dry run, default) or create the bridge links. :conflict links
    # are always skipped — never backed up, never overwritten.
    # harnesses: nil means "detected in the repo"; all: true means every
    # supported harness (for teams whose members don't all have every
    # agent installed).
    def link(dir, harnesses: nil, execute: false, all: false)
      if all && harnesses
        raise Error, "cannot combine 'all' with a specific harness (#{harnesses})"
      end
      repo_root = find_root(dir)
      targets = all ? REPO_BRIDGES.keys : (harnesses ? [harnesses] : detected(repo_root))
      if targets.empty?
        Reporter.info "no supported harness detected in this repo — " \
                      "use --harness ID to bridge one explicitly, or --all for every supported harness"
        return
      end
      links = plan(repo_root, targets)
      created = 0
      skipped = 0
      ok_count = 0

      links.each do |link|
        case link.status
        when :ok
          ok_count += 1
          next
        when :conflict
          Reporter.warn "skipped #{rel(repo_root, link.target)}: already exists — consolidate manually"
          skipped += 1
          next
        end

        if execute
          FileUtils.mkdir_p(File.dirname(link.target))
          File.symlink(link.rel_target, link.target)
          Reporter.ok "linked #{rel(repo_root, link.target)} → #{link.rel_target}"
          created += 1
        else
          Reporter.info "would create #{rel(repo_root, link.target)} → #{link.rel_target}"
          created += 1
        end
      end

      action = execute ? "linked" : "would be created"
      summary = +"#{created} link(s) #{action}"
      summary << ", #{ok_count} already ok" if ok_count.positive?
      summary << ", #{skipped} skipped" if skipped.positive?
      Reporter.info summary
      Reporter.info "run with --execute to create the links" if !execute && created.positive?
    end
  end

  # Thor subcommand: clpr repo ...
  class RepoCLI < Thor
    class_option :no_color, type: :boolean, default: false

    desc "check [DIR]", "Report issues with a repo's agent files and bridge links (default: cwd)"
    def check(dir = Dir.pwd)
      errors = Repo.check(dir)
      exit(errors.positive? ? 1 : 0)
    end

    desc "link [DIR]", "Show (dry run) or create symlink bridges for a repo's agent files (default: cwd)"
    option :execute, type: :boolean, desc: "Create the links (default is dry run)"
    option :harness, desc: "Bridge only this harness id (default: all detected in the repo)"
    option :all, type: :boolean, desc: "Bridge every supported harness, detected or not (team repos)"
    def link(dir = Dir.pwd)
      Repo.link(dir, harnesses: options[:harness], execute: options[:execute], all: options[:all])
    end
  end
end
