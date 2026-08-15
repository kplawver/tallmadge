# frozen_string_literal: true

require_relative "test_helper"

class OnboarderTest < Minitest::Test
  include TallmadgeTestHelpers

  def test_onboarding_fresh_environment_creates_skeleton
    FileUtils.rm_rf(home(".agents"))
    FileUtils.rm_rf(home(".tallmadge"))

    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.run(non_interactive: true, auto_yes: true) }

    assert_match(/No existing unmanaged \.agents directory/, out)
    assert Dir.exist?(home(".agents"))
    assert Dir.exist?(home(".tallmadge"))
  end

  def test_onboarding_backs_up_and_imports_existing_agents_dir
    # Setup an unmanaged existing ~/.agents directory
    FileUtils.rm_rf(home(".agents"))
    write home(".agents", "skills", "custom-skill", "SKILL.md"), skill_md(name: "custom-skill", description: "My custom skill")
    write home(".agents", "agents", "my-agent", "agent.md"), "---\nname: my-agent\n---\nAgent instructions\n"
    write home(".agents", "agents.md"), "# Precious User Instructions\n"
    write home(".agents", "mcp.json"), JSON.pretty_generate({ "mcpServers" => { "custom-mcp" => { "command" => "custom-cmd" } } })

    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.run(non_interactive: true, auto_yes: true) }

    assert_match(%r{Found existing unmanaged ~/.agents directory}, out)
    assert_match(%r{Backing up ~/.agents to}, out)
    assert_match(/Migrated existing imported-agents into Tallmadge store/, out)

    # Verify backup exists in ~/.tallmadge/backups/
    backups = Dir.glob(home(".tallmadge", "backups", "*-agents-backup"))
    assert_equal 1, backups.size
    backup_dir = backups.first
    assert File.file?(File.join(backup_dir, "agents.md"))
    assert File.file?(File.join(backup_dir, "mcp.json"))

    # Verify imported plugin registered in state
    s = state
    assert s.plugins.key?("imported-agents")
    assert s.profile_plugins["imported-agents"].dig("components", "skills", "custom-skill", "active")
    assert s.profile_plugins["imported-agents"].dig("components", "agents", "my-agent", "active")

    # Verify userContent saved in profile
    assert_equal "profiles/default/agents.md", s.user_content["agentsMd"]
    assert_equal "profiles/default/mcp.json", s.user_content["mcpJson"]

    # Verify composed files in ~/.agents
    assert File.symlink?(home(".agents", "skills", "custom-skill"))
    assert File.file?(home(".agents", "agents.md"))
    assert_includes File.read(home(".agents", "agents.md")), "Precious User Instructions"
    assert File.file?(home(".agents", "mcp.json"))
    mcp_data = JSON.parse(File.read(home(".agents", "mcp.json")))
    assert mcp_data["mcpServers"].key?("custom-mcp")
  end

  def test_onboarding_skips_when_already_managed
    # Create managed state and links
    write store("plugin1", "skills", "s1", "SKILL.md"), skill_md(name: "s1")
    s = state
    s.plugins["plugin1"] = {
      "installedAt" => Time.now.utc.iso8601,
      "updatedAt" => Time.now.utc.iso8601,
      "source" => { "type" => "path", "path" => store("plugin1") },
      "components" => { "skills" => { "s1" => { "active" => true } }, "agents" => {}, "tasks" => {}, "memories" => {}, "mcpServers" => {}, "agentsMd" => nil }
    }
    s.ensure_profile_plugin!("plugin1")
    Tallmadge::Activator.new(s).activate("plugin1")

    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.run(non_interactive: true, auto_yes: true) }

    assert_match(/already managed by Tallmadge/, out)
    refute_match(/imported-agents/, out)
  end

  def test_onboarding_imports_external_mcp_servers
    # Simulate Claude desktop config and Cursor config
    write home("Library", "Application Support", "Claude", "claude_desktop_config.json"), JSON.pretty_generate({
      "mcpServers" => {
        "claude-server" => { "command" => "npx", "args" => ["claude-srv"] }
      }
    })
    write home(".cursor", "mcp.json"), JSON.pretty_generate({
      "mcpServers" => {
        "cursor-server" => { "command" => "node", "args" => ["cursor-srv.js"] }
      }
    })

    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.run(non_interactive: true, auto_yes: true) }

    assert_match(/Found external MCP server configurations/, out)
    assert_match(/Imported 2 MCP server\(s\)/, out)

    s = state
    assert_equal "profiles/default/mcp.json", s.user_content["mcpJson"]

    # Verify servers merged into mcp.json
    user_mcp = JSON.parse(File.read(home(".tallmadge", "profiles", "default", "mcp.json")))
    assert user_mcp["mcpServers"].key?("claude-server")
    assert user_mcp["mcpServers"].key?("cursor-server")
  end

  def test_onboarding_imports_external_harness_plugins
    # Simulate Claude Code installed plugin
    ext_plugin_dir = home("external-claude-plugin")
    write File.join(ext_plugin_dir, ".claude-plugin", "plugin.json"), JSON.pretty_generate({ "name" => "External Plugin" })
    write File.join(ext_plugin_dir, "skills", "ext-skill", "SKILL.md"), skill_md(name: "ext-skill")

    write home(".claude", "plugins", "installed_plugins.json"), JSON.pretty_generate({
      "plugins" => {
        "ext-plugin" => {
          "installPath" => ext_plugin_dir,
          "version" => "1.0.0"
        }
      }
    })

    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.run(non_interactive: true, auto_yes: true) }

    assert_match(/Found external plugins from other harnesses/, out)
    assert_match(/Imported and activated plugin/, out)

    s = state
    assert s.plugins.key?("ext-plugin")
    assert s.profile_plugins["ext-plugin"].dig("components", "skills", "ext-skill", "active")
    assert File.symlink?(home(".agents", "skills", "ext-skill"))
  end
end
