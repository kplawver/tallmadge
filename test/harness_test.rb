# frozen_string_literal: true

require_relative "test_helper"

class HarnessTest < Minitest::Test
  include HandlrTestHelpers

  def setup_harness_homes
    FileUtils.mkdir_p(home(".omp", "agent"))
    FileUtils.mkdir_p(home(".pi", "agent"))
  end

  def install_agent_plugin(id: "hp")
    dir = home("fixture", id)
    write File.join(dir, "agents", "worker", "agent.md"), "---\nname: worker\n---\nWork\n"
    write File.join(dir, "AGENTS.md"), "HP instructions"
    capture_io { Handlr::Installer.new(state).install_path(dir, as: id) }
    capture_io { Handlr::Activator.new(state).activate(id) }
  end

  def test_omp_creates_flat_agent_file_link
    setup_harness_homes
    install_agent_plugin
    capture_io { Handlr::Harness.link(state, "omp") }

    link = home(".omp", "agent", "agents", "worker.md")
    assert File.symlink?(link)
    assert_equal agents("agents", "worker", "agent.md"), File.readlink(link)
    assert state.harnesses.dig("omp", "links", link)
  end

  def test_omp_no_links_for_skills_or_agents_md
    setup_harness_homes
    install_agent_plugin
    capture_io { Handlr::Harness.link(state, "omp") }
    links = state.harnesses.dig("omp", "links").keys
    assert links.none? { |l| l.include?("skills") }
    assert links.none? { |l| l.end_with?("AGENTS.md") }
  end

  def test_pi_creates_agents_md_link
    setup_harness_homes
    install_agent_plugin
    capture_io { Handlr::Harness.link(state, "pi") }
    link = home(".pi", "agent", "AGENTS.md")
    assert File.symlink?(link)
    assert_equal agents("agents.md"), File.readlink(link)
  end

  def test_pi_skips_when_agents_md_absent
    setup_harness_homes
    install_agent_plugin
    capture_io { Handlr::Activator.new(state).deactivate("hp") }
    refute File.exist?(agents("agents.md"))

    capture_io { Handlr::Harness.link(state, "pi") }
    refute File.symlink?(home(".pi", "agent", "AGENTS.md"))
    assert_empty state.harnesses.dig("pi", "links")
  end

  def test_conflict_skips_without_force_backs_up_with_force
    setup_harness_homes
    install_agent_plugin
    write home(".pi", "agent", "AGENTS.md"), "precious\n"

    out, = capture_io { Handlr::Harness.link(state, "pi") }
    assert_match(/skipping/, out)
    assert_equal "precious\n", File.read(home(".pi", "agent", "AGENTS.md"))

    capture_io { Handlr::Harness.link(state, "pi", force: true) }
    assert File.symlink?(home(".pi", "agent", "AGENTS.md"))
    backups = Dir.children(home(".handlr", "backups")).select { |b| b.end_with?("pi-AGENTS.md") }
    assert_equal 1, backups.size
    assert_equal "precious\n", File.read(File.join(home(".handlr", "backups"), backups.first))
  end

  def test_unlink_removes_only_recorded_links
    setup_harness_homes
    install_agent_plugin
    capture_io { Handlr::Harness.link(state, "omp") }
    write home(".omp", "agent", "agents", "foreign.md"), "not ours\n"

    capture_io { Handlr::Harness.unlink(state, "omp") }
    refute File.exist?(home(".omp", "agent", "agents", "worker.md"))
    assert File.exist?(home(".omp", "agent", "agents", "foreign.md"))
    assert_nil state.harnesses["omp"]
  end

  def test_auto_maintain_follows_activation_state
    setup_harness_homes
    install_agent_plugin
    capture_io { Handlr::Harness.link(state, "omp") }
    link = home(".omp", "agent", "agents", "worker.md")
    assert File.symlink?(link)

    capture_io { Handlr::Activator.new(state).deactivate("hp") }
    refute File.symlink?(link)

    capture_io { Handlr::Activator.new(state).activate("hp") }
    assert File.symlink?(link)
  end

  def test_link_requires_installed_harness
    err = assert_raises(Handlr::Error) do
      capture_io { Handlr::Harness.link(state, "omp") }
    end
    assert_match(/does not appear to be installed/, err.message)
  end

  def test_link_rejects_unknown_harness
    err = assert_raises(Handlr::Error) do
      capture_io { Handlr::Harness.link(state, "claude") }
    end
    assert_match(/unknown harness/, err.message)
  end
end
