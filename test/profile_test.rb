# frozen_string_literal: true

require_relative "test_helper"

class ProfileTest < Minitest::Test
  include TallmadgeTestHelpers

  def install_demo(id: "demo",
                   agents_md: "Demo instructions.",
                   mcp: '{"mcpServers":{"demo-srv":{"command":"echo"}}}')
    dir = home("fixture", id)
    write File.join(dir, "skills", "hello", "SKILL.md"), skill_md
    write File.join(dir, "agents", "greeter.md"), "---\nname: greeter\n---\nPrompt\n"
    write File.join(dir, "agents.md"), agents_md if agents_md
    write File.join(dir, "mcp.json"), mcp if mcp
    capture_io { Tallmadge::Installer.new(state).install_path(dir, as: id) }
  end

  def activate(id, **opts)
    capture_io { Tallmadge::Activator.new(state).activate(id, **opts) }
  end

  def deactivate(id, **opts)
    capture_io { Tallmadge::Activator.new(state).deactivate(id, **opts) }
  end

  # 1. Fresh state has one default profile active; clpr-level profile operations
  def test_profile_lifecycle_and_validation
    s = state
    assert_equal "default", s.active_profile_name
    assert_equal %w[default], s.profiles.keys

    # Create profile
    capture_io { Tallmadge::Profiles.create(s, "work") }
    assert_includes s.profiles.keys, "work"

    # Duplicate create raises
    assert_raises(Tallmadge::Error) { Tallmadge::Profiles.create(s, "work") }

    # Invalid name raises
    assert_raises(Tallmadge::Error) { Tallmadge::Profiles.create(s, "Bad Name!") }

    # Removing active profile raises
    assert_raises(Tallmadge::Error) { Tallmadge::Profiles.remove(s, "default") }

    # Removing unknown raises
    assert_raises(Tallmadge::Error) { Tallmadge::Profiles.remove(s, "nonexistent") }

    # Remove deletes profile dir
    work_dir = Tallmadge::Paths.profile_dir("work")
    FileUtils.mkdir_p(work_dir)
    assert Dir.exist?(work_dir)
    capture_io { Tallmadge::Profiles.remove(s, "work") }
    refute s.profiles.key?("work")
    refute Dir.exist?(work_dir)
  end

  # 2. Switching swaps symlinks and tracks active profile
  def test_switching_swaps_symlinks
    install_demo
    activate("demo")

    skill_link = agents("skills", "hello")
    assert File.symlink?(skill_link)

    s = state
    Tallmadge::Profiles.create(s, "work")
    capture_io { Tallmadge::Profiles.switch(s, "work") }

    assert_equal "work", s.active_profile_name
    refute File.exist?(skill_link)
    refute File.exist?(agents("agents.md"))
    refute File.exist?(agents("mcp.json"))

    # Activate demo inside work
    activate("demo")
    assert File.symlink?(skill_link)

    # Switch back to default
    s_fresh = state
    capture_io { Tallmadge::Profiles.switch(s_fresh, "default") }
    assert_equal "default", s_fresh.active_profile_name
    assert File.symlink?(skill_link)
  end

  # 3. Per-profile adopted AGENTS.md
  def test_per_profile_adopted_agents_md
    # With default active, write WORK CONTENT and activate demo (adoption)
    write agents("agents.md"), "WORK CONTENT\n"
    install_demo(agents_md: "Demo plugin instructions.")
    activate("demo")

    s = state
    Tallmadge::Profiles.create(s, "personal")
    capture_io { Tallmadge::Profiles.switch(s, "personal") }

    # In personal profile, write PERSONAL CONTENT and activate demo
    write agents("agents.md"), "PERSONAL CONTENT\n"
    s2 = state
    capture_io { Tallmadge::Activator.new(s2).activate("demo") }

    # In personal, composed agents.md contains PERSONAL CONTENT
    personal_content = File.read(agents("agents.md"))
    assert_includes personal_content, "PERSONAL CONTENT"
    refute_includes personal_content, "WORK CONTENT"

    # Switch back to default, composed agents.md contains WORK CONTENT
    s3 = state
    capture_io { Tallmadge::Profiles.switch(s3, "default") }
    default_content = File.read(agents("agents.md"))
    assert_includes default_content, "WORK CONTENT"
    refute_includes default_content, "PERSONAL CONTENT"

    # Switch back to personal again
    s4 = state
    capture_io { Tallmadge::Profiles.switch(s4, "personal") }
    personal_content_again = File.read(agents("agents.md"))
    assert_includes personal_content_again, "PERSONAL CONTENT"
    refute_includes personal_content_again, "WORK CONTENT"
  end

  # 4. Per-profile marketplaces
  def test_per_profile_marketplaces
    catalog_dir = home("fixture", "marketplace")
    catalog_json = <<~JSON
      {
        "name": "fixture-cat",
        "owner": { "name": "test" },
        "plugins": [
          { "name": "sample", "source": "./sample" }
        ]
      }
    JSON
    write File.join(catalog_dir, ".claude-plugin", "marketplace.json"), catalog_json
    write File.join(catalog_dir, "sample", "skills", "sample", "SKILL.md"), skill_md

    s = state
    capture_io { Tallmadge::Marketplace.add(s, catalog_dir) }
    assert_includes s.profile_marketplaces, "fixture-cat"

    Tallmadge::Profiles.create(s, "work")
    capture_io { Tallmadge::Profiles.switch(s, "work") }

    out, = capture_io { Tallmadge::Marketplace.list(s) }
    assert_match(/no marketplaces added/, out)

    # Re-add the same path in work profile (inclusion)
    out2, = capture_io { Tallmadge::Marketplace.add(s, catalog_dir) }
    assert_match(/already added; included in profile work/, out2)
    assert_includes s.profile_marketplaces, "fixture-cat"

    # Removing in work leaves catalog listed in default
    capture_io { Tallmadge::Marketplace.remove(s, "fixture-cat") }
    refute_includes s.profile_marketplaces, "fixture-cat"
    assert s.marketplaces.key?("fixture-cat")

    capture_io { Tallmadge::Profiles.switch(s, "default") }
    assert_includes s.profile_marketplaces, "fixture-cat"

    # Removing in default deletes global record and dir
    capture_io { Tallmadge::Marketplace.remove(s, "fixture-cat") }
    refute s.marketplaces.key?("fixture-cat")
  end

  # 5. v1 migration
  def test_v1_migration
    v1_state = {
      "version" => 1,
      "marketplaces" => {
        "legacy-cat" => {
          "source" => { "type" => "path", "path" => "/tmp/cat" },
          "path" => "/tmp/cat",
          "sha" => nil,
          "updatedAt" => "2026-08-01T00:00:00Z"
        }
      },
      "plugins" => {
        "demo" => {
          "displayName" => "Demo",
          "description" => "Demo plugin",
          "source" => { "type" => "path", "path" => "/tmp/demo" },
          "installedAt" => "2026-08-01T00:00:00Z",
          "updatedAt" => "2026-08-01T00:00:00Z",
          "components" => {
            "skills" => {
              "hello" => { "active" => true }
            },
            "agentsMd" => { "active" => true }
          }
        }
      },
      "harnesses" => {
        "omp" => { "links" => { "/tmp/target" => "/tmp/source" } }
      },
      "mcpOrigins" => { "srv" => "demo" },
      "userContent" => { "agentsMd" => "store/user/agents.md", "mcpJson" => nil },
      "composed" => { "agentsMd" => true, "mcpJson" => false }
    }

    state_path = home(".tallmadge", "state.json")
    write state_path, JSON.pretty_generate(v1_state)

    loaded = Tallmadge::State.load
    assert_equal 2, loaded.data["version"]
    assert_equal "default", loaded.active_profile_name
    assert loaded.plugins.key?("demo")
    assert loaded.marketplaces.key?("legacy-cat")
    assert loaded.profile_plugins["demo"].dig("components", "skills", "hello", "active")
    assert_equal "store/user/agents.md", loaded.user_content["agentsMd"]
    assert_equal({ "srv" => "demo" }, loaded.mcp_origins)
    assert_equal true, loaded.composed["agentsMd"]
    assert_equal({ "/tmp/target" => "/tmp/source" }, loaded.harnesses["omp"]["links"])

    # Verify on-disk file was rewritten to v2
    raw_disk = JSON.parse(File.read(state_path))
    assert_equal 2, raw_disk["version"]
    assert_equal "default", raw_disk["activeProfile"]
    assert raw_disk.key?("profiles")
    refute raw_disk.key?("harnesses")
    refute raw_disk.key?("mcpOrigins")
  end
end
