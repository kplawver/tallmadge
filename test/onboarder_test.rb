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
    assert_match(%r{Migrated 2 standalone plugin\(s\) from prior ~/.agents into Tallmadge store}, out)

    # Verify backup exists in ~/.tallmadge/backups/
    backups = Dir.glob(home(".tallmadge", "backups", "*-agents-backup"))
    assert_equal 1, backups.size
    backup_dir = backups.first
    assert File.file?(File.join(backup_dir, "agents.md"))
    assert File.file?(File.join(backup_dir, "mcp.json"))

    # Verify imported plugins registered individually in state
    s = state
    assert s.plugins.key?("custom-skill")
    assert s.plugins.key?("my-agent")
    assert s.profile_plugins["custom-skill"].dig("components", "skills", "custom-skill", "active")
    assert s.profile_plugins["my-agent"].dig("components", "agents", "my-agent", "active")

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

  def test_onboarding_groups_skill_families_and_symlink_sources_into_single_plugins
    FileUtils.rm_rf(home(".agents"))

    # Plain name-prefix family: root skill present + suffixed siblings
    %w[caveman caveman-commit caveman-review].each do |name|
      write home(".agents", "skills", name, "SKILL.md"), skill_md(name: name)
    end

    # Unrelated skill with no family stays standalone
    write home(".agents", "skills", "standalone", "SKILL.md"), skill_md(name: "standalone")

    # Symlinked skills sharing one real source directory
    write home("src", "ponytail", "skills", "one", "SKILL.md"), skill_md(name: "one")
    write home("src", "ponytail", "skills", "two", "SKILL.md"), skill_md(name: "two")
    File.symlink(home("src", "ponytail", "skills", "one"), home(".agents", "skills", "one"))
    File.symlink(home("src", "ponytail", "skills", "two"), home(".agents", "skills", "two"))

    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.run(non_interactive: true, auto_yes: true) }

    assert_match(/Imported skills: caveman \(3 components: caveman, caveman-commit, caveman-review\)/, out)
    assert_match(/Imported skills: ponytail \(2 components: one, two\)/, out)
    assert_match(/Imported skill: standalone/, out)
    assert_match(/Migrated 3 standalone plugin\(s\)/, out)

    s = state
    assert_equal %w[caveman caveman-commit caveman-review], s.plugins["caveman"]["components"]["skills"].keys.sort
    assert_equal 3, s.profile_plugins["caveman"]["components"]["skills"].values.count { |info| info["active"] }
    assert_equal %w[one two], s.plugins["ponytail"]["components"]["skills"].keys.sort
    assert s.plugins.key?("standalone")

    %w[caveman caveman-commit caveman-review standalone one two].each do |name|
      assert File.symlink?(home(".agents", "skills", name)), "#{name} should be relinked"
    end
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

  def test_onboarding_deduplicates_mcp_servers
    FileUtils.rm_rf(home(".agents"))
    # Pre-populate user mcp.json in default profile so dup-server is already present
    write home(".tallmadge", "profiles", "default", "mcp.json"), JSON.pretty_generate({
      "mcpServers" => {
        "dup-server" => { "command" => "existing-cmd" }
      }
    })

    # Setup Claude desktop config with overlapping server name
    write home("Library", "Application Support", "Claude", "claude_desktop_config.json"), JSON.pretty_generate({
      "mcpServers" => {
        "dup-server" => { "command" => "npx", "args" => ["claude-srv"] },
        "unique-server" => { "command" => "node", "args" => ["unique.js"] }
      }
    })

    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.run(non_interactive: true, auto_yes: true) }

    assert_match(/skipping duplicate/, out)
    assert_match(/Imported 1 MCP server\(s\) into profile 'default' \(1 skipped\/deduped\)/, out)

    user_mcp = JSON.parse(File.read(home(".tallmadge", "profiles", "default", "mcp.json")))
    assert user_mcp["mcpServers"].key?("dup-server")
    assert user_mcp["mcpServers"].key?("unique-server")
    assert_equal "existing-cmd", user_mcp["mcpServers"]["dup-server"]["command"]
  end

  def test_onboarding_deduplicates_marketplaces_and_plugins
    FileUtils.rm_rf(home(".agents"))

    # Create marketplace directory and file
    mp_dir = home("mp")
    write File.join(mp_dir, ".claude-plugin", "marketplace.json"), JSON.pretty_generate({
      "name" => "test-mp",
      "owner" => { "name" => "test" },
      "plugins" => []
    })

    # Add marketplace to state first
    s = state
    Tallmadge::Marketplace.add(s, mp_dir)

    # Setup Claude known_marketplaces.json referencing same marketplace
    write home(".claude", "plugins", "known_marketplaces.json"), JSON.pretty_generate({
      "test-mp" => {
        "source" => { "source" => "path", "path" => mp_dir },
        "installLocation" => mp_dir
      }
    })

    # Setup external plugin that is already installed
    ext_plugin_dir = home("external-plugin")
    write File.join(ext_plugin_dir, ".claude-plugin", "plugin.json"), JSON.pretty_generate({ "name" => "Dup Plugin" })
    write File.join(ext_plugin_dir, "skills", "dup-skill", "SKILL.md"), skill_md(name: "dup-skill")

    Tallmadge::Installer.new(s).install_path(ext_plugin_dir, as: "dup-plugin")

    write home(".claude", "plugins", "installed_plugins.json"), JSON.pretty_generate({
      "plugins" => {
        "dup-plugin" => {
          "installPath" => ext_plugin_dir
        }
      }
    })

    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.run(non_interactive: true, auto_yes: true) }

    assert_match(/Plugin 'dup-plugin' already installed/, out)
    assert_match(/Marketplace import complete: 0 added, 1 skipped\/deduped/, out)
    assert_match(/Plugin import complete: 0 imported, 1 skipped\/deduped/, out)
  end

  def test_restore_removes_tallmadge_management_and_restores_backup
    # 1. Start with an existing ~/.agents with real non-symlink files
    FileUtils.rm_rf(home(".agents"))
    write home(".agents", "skills", "precious-skill", "SKILL.md"), skill_md(name: "precious-skill")
    write home(".agents", "agents.md"), "# Original Precious Instructions\n"
    write home(".agents", "mcp.json"), JSON.pretty_generate({ "mcpServers" => { "orig-server" => { "command" => "orig" } } })

    # 2. Run onboarding to back up and manage it
    onboarder = Tallmadge::Onboarder.new(state)
    capture_io { onboarder.run(non_interactive: true, auto_yes: true) }

    assert File.symlink?(home(".agents", "skills", "precious-skill"))
    assert state.composed["agentsMd"]

    # 3. Call restore
    out, = capture_io { onboarder.restore(non_interactive: true, auto_yes: true) }
    assert_match(%r{Tallmadge management removed and ~/.agents restored successfully}, out)

    # 4. Verify ~/.agents has restored non-symlinked original files
    refute File.symlink?(home(".agents", "skills", "precious-skill"))
    assert File.file?(home(".agents", "skills", "precious-skill", "SKILL.md"))
    assert_equal "# Original Precious Instructions\n", File.read(home(".agents", "agents.md"))
    mcp_data = JSON.parse(File.read(home(".agents", "mcp.json")))
    assert_equal({ "mcpServers" => { "orig-server" => { "command" => "orig" } } }, mcp_data)

    # 5. Verify state was cleaned up
    s = state
    assert_nil s.user_content["agentsMd"]
    assert_nil s.user_content["mcpJson"]
    assert_equal false, s.composed["agentsMd"]
    assert_equal false, s.composed["mcpJson"]
  end

  def test_restore_raises_if_no_backup_found
    FileUtils.rm_rf(home(".tallmadge", "backups"))
    onboarder = Tallmadge::Onboarder.new(state)

    err = assert_raises(Tallmadge::Error) do
      onboarder.restore(non_interactive: true, auto_yes: true)
    end
    assert_match(%r{No ~/.agents backup found}, err.message)
  end

  # ---- refresh ----

  def test_refresh_imports_new_mcp_servers
    write home("Library", "Application Support", "Claude", "claude_desktop_config.json"), JSON.pretty_generate({
      "mcpServers" => {
        "claude-server" => { "command" => "npx", "args" => ["-y", "claude-srv"] }
      }
    })

    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.refresh(non_interactive: true, auto_yes: true) }

    assert_match(/Refresh complete/, out)
    user_mcp = JSON.parse(File.read(home(".tallmadge", "profiles", "default", "mcp.json")))
    assert user_mcp["mcpServers"].key?("claude-server")
  end

  def test_refresh_imports_servers_from_newer_harness_config_locations
    write home(".cline", "data", "settings", "cline_mcp_settings.json"), JSON.pretty_generate({
      "mcpServers" => { "cline-server" => { "command" => "node", "args" => ["cline.js"] } }
    })
    write home(".copilot", "mcp-config.json"), JSON.pretty_generate({
      "mcpServers" => { "copilot-server" => { "command" => "npx" } }
    })
    # Amp namespaces the same per-server shape under its own settings key.
    write home(".config", "amp", "settings.json"), JSON.pretty_generate({
      "amp.mcpServers" => { "amp-server" => { "url" => "https://example.com/mcp" } }
    })

    capture_io { Tallmadge::Onboarder.new(state).refresh(non_interactive: true, auto_yes: true) }

    servers = JSON.parse(File.read(home(".tallmadge", "profiles", "default", "mcp.json")))["mcpServers"]
    assert servers.key?("cline-server")
    assert servers.key?("copilot-server")
    assert_equal "https://example.com/mcp", servers.dig("amp-server", "url")
  end

  def test_refresh_deduplicates_already_imported_mcp_servers
    write home("Library", "Application Support", "Claude", "claude_desktop_config.json"), JSON.pretty_generate({
      "mcpServers" => {
        "dup-server" => { "command" => "existing" }
      }
    })

    # First import via setup
    onboarder = Tallmadge::Onboarder.new(state)
    capture_io { onboarder.refresh(non_interactive: true, auto_yes: true) }

    # Second refresh should dedup
    out, = capture_io { onboarder.refresh(non_interactive: true, auto_yes: true) }
    assert_match(/skipped\/deduped/, out)
  end

  def test_refresh_detects_and_links_newly_installed_harness
    FileUtils.mkdir_p(home(".omp", "agent"))

    # Install and activate an agent plugin so there's something to bridge
    dir = home("fixture", "agent-plugin")
    write File.join(dir, "agents", "worker", "agent.md"), "---\nname: worker\n---\nWork\n"
    capture_io { Tallmadge::Installer.new(state).install_path(dir, as: "agent-plugin") }
    capture_io { Tallmadge::Activator.new(state).activate("agent-plugin") }

    refute state.harnesses.key?("omp")

    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.refresh(non_interactive: true, auto_yes: true) }

    assert_match(/Newly detected harnesses: omp/, out)
    assert_match(/Refresh complete/, out)
    s = state
    assert s.harnesses.key?("omp")
    link = home(".omp", "agent", "agents", "worker.md")
    assert File.symlink?(link)
  end

  def test_refresh_asks_before_bridging_newly_detected_harnesses
    FileUtils.mkdir_p(home(".omp", "agent"))

    dir = home("fixture", "agent-plugin")
    write File.join(dir, "agents", "worker", "agent.md"), "---\nname: worker\n---\nWork\n"
    capture_io { Tallmadge::Installer.new(state).install_path(dir, as: "agent-plugin") }
    capture_io { Tallmadge::Activator.new(state).activate("agent-plugin") }

    onboarder = Tallmadge::Onboarder.new(state, input: StringIO.new("n\n"))
    out, = capture_io { onboarder.refresh }

    assert_match(/clpr link HARNESS/, out)
    refute state.harnesses.key?("omp"), "declining the prompt must not link the harness"
    refute File.symlink?(home(".omp", "agent", "agents", "worker.md"))
  end

  def test_refresh_imports_devin_servers_from_pre_migration_config
    write home(".config", "devin", "config.json"), JSON.pretty_generate({
      "mcpServers" => { "devin-server" => { "command" => "node", "args" => ["srv.js"] } }
    })

    capture_io { Tallmadge::Onboarder.new(state).refresh(non_interactive: true, auto_yes: true) }

    servers = JSON.parse(File.read(home(".tallmadge", "profiles", "default", "mcp.json")))["mcpServers"]
    assert servers.key?("devin-server")
  end

  def test_refresh_preserves_existing_symlinks
    dir = home("fixture", "my-plugin")
    write File.join(dir, "skills", "my-skill", "SKILL.md"), skill_md(name: "my-skill")
    capture_io { Tallmadge::Installer.new(state).install_path(dir, as: "my-plugin") }
    capture_io { Tallmadge::Activator.new(state).activate("my-plugin") }

    assert File.symlink?(agents("skills", "my-skill"))

    onboarder = Tallmadge::Onboarder.new(state)
    capture_io { onboarder.refresh(non_interactive: true, auto_yes: true) }

    assert File.symlink?(agents("skills", "my-skill")), "symlink should survive refresh"
  end

  def test_refresh_safe_when_nothing_new
    onboarder = Tallmadge::Onboarder.new(state)
    out, = capture_io { onboarder.refresh(non_interactive: true, auto_yes: true) }

    assert_match(/Refresh complete/, out)
  end
end
