# frozen_string_literal: true

require_relative "test_helper"

class HarnessTest < Minitest::Test
  include TallmadgeTestHelpers

  def setup_harness_homes
    FileUtils.mkdir_p(home(".omp", "agent"))
    FileUtils.mkdir_p(home(".pi", "agent"))
  end

  def install_agent_plugin(id: "hp")
    dir = home("fixture", id)
    write File.join(dir, "agents", "worker", "agent.md"), "---\nname: worker\n---\nWork\n"
    write File.join(dir, "AGENTS.md"), "HP instructions"
    capture_io { Tallmadge::Installer.new(state).install_path(dir, as: id) }
    capture_io { Tallmadge::Activator.new(state).activate(id) }
  end

  def test_omp_creates_flat_agent_file_link
    setup_harness_homes
    install_agent_plugin
    capture_io { Tallmadge::Harness.link(state, "omp") }

    link = home(".omp", "agent", "agents", "worker.md")
    assert File.symlink?(link)
    assert_equal agents("agents", "worker", "agent.md"), File.readlink(link)
    assert state.harnesses.dig("omp", "links", link)
  end

  def test_omp_no_links_for_skills_or_agents_md
    setup_harness_homes
    install_agent_plugin
    capture_io { Tallmadge::Harness.link(state, "omp") }
    # omp reads ~/.agents/agents.md and ~/.agents/skills itself, so nothing
    # is copied into its own home for either.
    links = state.harnesses.dig("omp", "links").keys.select { |l| l.include?("#{File::SEPARATOR}.omp#{File::SEPARATOR}") }
    refute_empty links
    assert links.none? { |l| l.include?("skills") }
    assert links.none? { |l| l.downcase.end_with?("agents.md") }
  end

  def test_pi_creates_agents_md_link
    setup_harness_homes
    install_agent_plugin
    capture_io { Tallmadge::Harness.link(state, "pi") }
    link = home(".pi", "agent", "AGENTS.md")
    assert File.symlink?(link)
    assert_equal agents("agents.md"), File.readlink(link)
  end

  def test_pi_skips_when_agents_md_absent
    setup_harness_homes
    install_agent_plugin
    capture_io { Tallmadge::Activator.new(state).deactivate("hp") }
    refute File.exist?(agents("agents.md"))

    capture_io { Tallmadge::Harness.link(state, "pi") }
    refute File.symlink?(home(".pi", "agent", "AGENTS.md"))
    assert_empty state.harnesses.dig("pi", "links")
  end

  def test_conflict_skips_without_force_backs_up_with_force
    setup_harness_homes
    install_agent_plugin
    write home(".pi", "agent", "AGENTS.md"), "precious\n"

    out, = capture_io { Tallmadge::Harness.link(state, "pi") }
    assert_match(/skipping/, out)
    assert_equal "precious\n", File.read(home(".pi", "agent", "AGENTS.md"))

    capture_io { Tallmadge::Harness.link(state, "pi", force: true) }
    assert File.symlink?(home(".pi", "agent", "AGENTS.md"))
    backups = Dir.children(home(".tallmadge", "backups")).select { |b| b.end_with?("pi-AGENTS.md") }
    assert_equal 1, backups.size
    assert_equal "precious\n", File.read(File.join(home(".tallmadge", "backups"), backups.first))
  end

  def test_unlink_removes_only_recorded_links
    setup_harness_homes
    install_agent_plugin
    capture_io { Tallmadge::Harness.link(state, "omp") }
    write home(".omp", "agent", "agents", "foreign.md"), "not ours\n"

    capture_io { Tallmadge::Harness.unlink(state, "omp") }
    refute File.exist?(home(".omp", "agent", "agents", "worker.md"))
    assert File.exist?(home(".omp", "agent", "agents", "foreign.md"))
    assert_nil state.harnesses["omp"]
  end

  def test_auto_maintain_follows_activation_state
    setup_harness_homes
    install_agent_plugin
    capture_io { Tallmadge::Harness.link(state, "omp") }
    link = home(".omp", "agent", "agents", "worker.md")
    assert File.symlink?(link)

    capture_io { Tallmadge::Activator.new(state).deactivate("hp") }
    refute File.symlink?(link)

    capture_io { Tallmadge::Activator.new(state).activate("hp") }
    assert File.symlink?(link)
  end

  def install_skill_plugin(id: "sp")
    dir = home("fixture", id)
    write File.join(dir, "skills", "sp-skill", "SKILL.md"),
          skill_md(name: "sp-skill", description: "Skill plugin fixture")
    capture_io { Tallmadge::Installer.new(state).install_path(dir, as: id) }
    capture_io { Tallmadge::Activator.new(state).activate(id) }
  end

  def test_doctor_reports_activated_links_as_managed
    setup_harness_homes
    install_skill_plugin

    out, = capture_io { Tallmadge::Harness.doctor(state) }
    assert_match(/#{agents('skills', 'sp-skill')}: managed link/, out)
    refute_match(/orphan/, out)
  end

  def test_doctor_flags_store_symlinks_missing_from_state_as_orphans
    setup_harness_homes
    install_skill_plugin
    FileUtils.ln_s(store("sp", "skills", "sp-skill"), agents("skills", "ghost"))

    out, = capture_io { Tallmadge::Harness.doctor(state) }
    assert_match(/#{agents('skills', 'sp-skill')}: managed link/, out)
    assert_match(/#{agents('skills', 'ghost')}: .* \(orphan\)/, out)
  end

  def test_doctor_ignores_ds_store_files
    setup_harness_homes
    write agents(".DS_Store"), "junk"
    write agents("skills", ".DS_Store"), "junk"
    write agents("skills", "real.md"), "genuinely unmanaged"

    out, = capture_io { Tallmadge::Harness.doctor(state) }
    refute_match(/DS_Store/, out)
    assert_match(/#{agents('skills', 'real.md')}: not managed/, out)
  end

  def test_link_requires_installed_harness
    err = assert_raises(Tallmadge::Error) do
      capture_io { Tallmadge::Harness.link(state, "omp") }
    end
    assert_match(/does not appear to be installed/, err.message)
  end

  def test_link_rejects_unknown_harness
    err = assert_raises(Tallmadge::Error) do
      capture_io { Tallmadge::Harness.link(state, "emacs-doctor") }
    end
    assert_match(/unknown harness/, err.message)
  end

  # ---- adapters beyond omp/pi ---------------------------------------------

  # A plugin that exercises every bridgeable slot at once.
  def install_full_plugin(id: "fp")
    dir = home("fixture", id)
    write File.join(dir, "agents", "worker", "agent.md"), "---\nname: worker\n---\nWork\n"
    write File.join(dir, "skills", "fp-skill", "SKILL.md"),
          skill_md(name: "fp-skill", description: "Full plugin fixture")
    write File.join(dir, "AGENTS.md"), "FP instructions"
    write File.join(dir, "mcp.json"), '{"mcpServers":{"fp-srv":{"command":"echo"}}}'
    capture_io { Tallmadge::Installer.new(state).install_path(dir, as: id) }
    capture_io { Tallmadge::Activator.new(state).activate(id) }
  end

  def test_claude_bridges_instructions_skills_and_flat_agents
    FileUtils.mkdir_p(home(".claude"))
    install_full_plugin
    capture_io { Tallmadge::Harness.link(state, "claude") }

    assert_equal agents("agents.md"), File.readlink(home(".claude", "CLAUDE.md"))
    assert_equal agents("skills", "fp-skill"), File.readlink(home(".claude", "skills", "fp-skill"))
    assert_equal agents("agents", "worker", "agent.md"),
                 File.readlink(home(".claude", "agents", "worker.md"))
  end

  def test_amp_bridges_only_instructions_because_skills_are_native
    FileUtils.mkdir_p(home(".config", "amp"))
    install_full_plugin
    capture_io { Tallmadge::Harness.link(state, "amp") }

    links = state.harnesses.dig("amp", "links").keys
    assert_equal [home(".config", "amp", "AGENTS.md")], links
  end

  def test_kilo_bridges_instructions_and_agents_under_config_dir
    FileUtils.mkdir_p(home(".config", "kilo"))
    install_full_plugin
    capture_io { Tallmadge::Harness.link(state, "kilo") }

    assert_equal agents("agents.md"), File.readlink(home(".config", "kilo", "AGENTS.md"))
    assert_equal agents("agents", "worker", "agent.md"),
                 File.readlink(home(".config", "kilo", "agent", "worker.md"))
  end

  def test_devin_bridges_agent_directories_and_mcp_config
    FileUtils.mkdir_p(home(".config", "devin"))
    install_full_plugin
    capture_io { Tallmadge::Harness.link(state, "devin") }

    assert_equal agents("agents", "worker"),
                 File.readlink(home(".config", "devin", "agents", "worker"))
    assert_equal agents("mcp.json"), File.readlink(home(".config", "devin", "mcp_config.json"))
  end

  def test_copilot_agent_links_use_the_agent_md_suffix
    FileUtils.mkdir_p(home(".copilot"))
    install_full_plugin
    capture_io { Tallmadge::Harness.link(state, "copilot") }

    assert File.symlink?(home(".copilot", "agents", "worker.agent.md"))
    assert_equal agents("agents.md"),
                 File.readlink(home(".copilot", "copilot-instructions.md"))
  end

  def test_cursor_bridges_mcp_but_not_instructions
    FileUtils.mkdir_p(home(".cursor"))
    install_full_plugin
    capture_io { Tallmadge::Harness.link(state, "cursor") }

    assert_equal agents("mcp.json"), File.readlink(home(".cursor", "mcp.json"))
    links = state.harnesses.dig("cursor", "links").keys
    assert links.none? { |l| l.end_with?("AGENTS.md") }
  end

  def test_cline_makes_the_composed_instructions_readable_at_uppercase_path
    FileUtils.mkdir_p(home(".cline"))
    install_full_plugin
    capture_io { Tallmadge::Harness.link(state, "cline") }

    # Cline stats ~/.agents/AGENTS.md literally; the composed file is
    # lowercase, so on a case-sensitive filesystem clpr adds the alias.
    assert File.exist?(agents("AGENTS.md"))
    assert_match(/managed by tallmadge/, File.read(agents("AGENTS.md")))
    if Tallmadge::Harness.case_sensitive_agents_home?
      assert_equal agents("agents.md"), File.readlink(agents("AGENTS.md"))
    else
      refute File.symlink?(agents("AGENTS.md"))
    end
  end

  def test_cline_skills_are_native_and_mcp_is_bridged
    FileUtils.mkdir_p(home(".cline"))
    install_full_plugin
    capture_io { Tallmadge::Harness.link(state, "cline") }

    links = state.harnesses.dig("cline", "links").keys
    assert links.none? { |l| l.include?("#{File::SEPARATOR}.cline#{File::SEPARATOR}skills") }
    assert_equal agents("mcp.json"),
                 File.readlink(home(".cline", "data", "settings", "cline_mcp_settings.json"))
  end

  def test_unlink_keeps_a_target_another_harness_still_expects
    skip "alias only exists on a case-sensitive filesystem" unless
      Tallmadge::Harness.case_sensitive_agents_home?

    FileUtils.mkdir_p(home(".cline"))
    FileUtils.mkdir_p(home(".omp", "agent"))
    install_full_plugin
    capture_io { Tallmadge::Harness.link(state, "cline") }
    capture_io { Tallmadge::Harness.link(state, "omp") }

    capture_io { Tallmadge::Harness.unlink(state, "omp") }
    assert File.symlink?(agents("AGENTS.md")), "cline still needs the uppercase alias"

    capture_io { Tallmadge::Harness.unlink(state, "cline") }
    refute File.symlink?(agents("AGENTS.md"))
  end

  def test_env_var_relocates_a_harness_home
    relocated = home("xdg", "codex")
    FileUtils.mkdir_p(relocated)
    install_full_plugin

    with_env("CODEX_HOME" => relocated) do
      capture_io { Tallmadge::Harness.link(state, "codex") }
      assert_equal agents("agents.md"), File.readlink(File.join(relocated, "AGENTS.md"))
    end
    refute File.exist?(home(".codex", "AGENTS.md"))
  end

  def test_link_all_covers_every_detected_harness
    FileUtils.mkdir_p(home(".claude"))
    FileUtils.mkdir_p(home(".gemini"))
    install_full_plugin

    capture_io { Tallmadge::Harness.link(state) }
    assert_equal agents("agents.md"), File.readlink(home(".gemini", "GEMINI.md"))
    assert File.symlink?(home(".claude", "CLAUDE.md"))
  end

  def with_env(vars)
    previous = vars.keys.to_h { |key| [key, ENV[key]] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
