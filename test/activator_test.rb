# frozen_string_literal: true

require_relative "test_helper"

class ActivatorTest < Minitest::Test
  include TallmadgeTestHelpers

  def install_demo(id: "demo",
                   agents_md: "Demo instructions.",
                   mcp: '{"mcpServers":{"demo-srv":{"command":"echo"}}}')
    dir = home("fixture", id)
    write File.join(dir, "skills", "hello", "SKILL.md"), skill_md
    write File.join(dir, "agents", "greeter", "agent.md"), "---\nname: greeter\n---\nGreet\n"
    write File.join(dir, "AGENTS.md"), agents_md if agents_md
    write File.join(dir, "mcp.json"), mcp if mcp
    capture_io { Tallmadge::Installer.new(state).install_path(dir, as: id) }
  end

  def activate(id, **opts)
    capture_io { Tallmadge::Activator.new(state).activate(id, **opts) }
  end

  def deactivate(id, **opts)
    capture_io { Tallmadge::Activator.new(state).deactivate(id, **opts) }
  end

  def test_activate_creates_correct_symlinks
    install_demo
    activate("demo")

    skill_link = agents("skills", "hello")
    agent_link = agents("agents", "greeter")
    assert File.symlink?(skill_link)
    assert File.symlink?(agent_link)
    assert_equal File.realpath(store("demo", "skills", "hello")), File.realpath(skill_link)
    assert_equal File.realpath(store("demo", "agents", "greeter")), File.realpath(agent_link)

    entry = state.profile_plugins["demo"]
    assert entry.dig("components", "skills", "hello", "active")
    assert entry.dig("components", "agentsMd", "active")
  end

  def test_conflict_raises_without_force
    install_demo
    activate("demo")

    dir2 = home("fixture", "other")
    write File.join(dir2, "skills", "hello", "SKILL.md"), skill_md
    capture_io { Tallmadge::Installer.new(state).install_path(dir2, as: "other") }

    err = assert_raises(Tallmadge::Error) { activate("other") }
    assert_match(/already exists/, err.message)
  end

  def test_force_backs_up_conflict_and_relinks
    install_demo
    activate("demo")

    dir2 = home("fixture", "other")
    write File.join(dir2, "skills", "hello", "SKILL.md"), skill_md
    capture_io { Tallmadge::Installer.new(state).install_path(dir2, as: "other") }

    activate("other", force: true)
    backups = Dir.children(home(".tallmadge", "backups")).select { |b| b.include?("skills-hello") }
    refute_empty backups
    assert_equal File.realpath(store("other", "skills", "hello")),
                 File.realpath(agents("skills", "hello"))
  end

  def test_compose_agents_md_with_adoption
    write agents("agents.md"), "USER CONTENT\n"
    install_demo
    activate("demo")

    content = File.read(agents("agents.md"))
    assert content.start_with?(Tallmadge::Activator::AGENTS_MD_MARKER)
    assert_includes content, "USER CONTENT"
    assert_includes content, "<!-- tallmadge:begin demo -->"
    assert_includes content, "Demo instructions."
    assert_includes content, "<!-- tallmadge:end demo -->"
    # adoption preserved the user fragment
    assert_equal "USER CONTENT\n", File.read(File.join(Tallmadge::Paths.profile_dir("default"), "agents.md"))
    assert state.composed["agentsMd"]
  end

  def test_mcp_union_user_baseline_and_duplicate_warning
    write agents("mcp.json"), '{"mcpServers":{"user-srv":{"command":"u"}}}'
    install_demo
    activate("demo")

    data = JSON.parse(File.read(agents("mcp.json")))
    assert data["mcpServers"].key?("user-srv")
    assert data["mcpServers"].key?("demo-srv")
    assert_equal "user", state.mcp_origins["user-srv"]
    assert_equal "demo", state.mcp_origins["demo-srv"]

    dir2 = home("fixture", "dup")
    write File.join(dir2, "mcp.json"), '{"mcpServers":{"demo-srv":{"command":"other"}}}'
    capture_io { Tallmadge::Installer.new(state).install_path(dir2, as: "dup") }

    out, = activate("dup")
    assert_match(/already provided/, out)
    merged = JSON.parse(File.read(agents("mcp.json")))
    assert_equal "echo", merged["mcpServers"]["demo-srv"]["command"] # first wins
  end

  def test_deactivate_removes_only_own_links
    install_demo
    activate("demo")

    # Replace the skill symlink with a real directory handlr does not own.
    target = agents("skills", "hello")
    File.delete(target)
    FileUtils.mkdir_p(target)
    write File.join(target, "SKILL.md"), "user content"

    out, = deactivate("demo")
    assert File.directory?(target) # left in place
    assert_match(/not a tallmadge link/, out)
    refute state.profile_plugins["demo"].dig("components", "skills", "hello", "active")
  end

  def test_deactivate_recomposes_and_removes_composed_file
    install_demo
    activate("demo")
    assert File.exist?(agents("agents.md"))
    deactivate("demo")
    refute File.exist?(agents("agents.md"))
    refute File.exist?(agents("mcp.json"))
    refute state.composed["agentsMd"]
  end

  def test_activate_only_selected_component
    install_demo
    activate("demo", only: [["skills", "hello"]])
    assert File.symlink?(agents("skills", "hello"))
    refute File.symlink?(agents("agents", "greeter"))
    refute state.plugins["demo"].dig("components", "agents", "greeter", "active")
  end
end
