# frozen_string_literal: true

require_relative "test_helper"

class McpTest < Minitest::Test
  include TallmadgeTestHelpers

  def install_plugin(id, mcp_json)
    dir = home("fixture", id)
    write File.join(dir, "skills", "hello", "SKILL.md"), skill_md
    write File.join(dir, "mcp.json"), mcp_json
    capture_io { Tallmadge::Installer.new(state).install_path(dir, as: id) }
  end

  # CLI.start rescues Tallmadge::Error into Reporter.err + exit(1), so a
  # failing command surfaces as SystemExit — never let it kill the run.
  def run_cli(*args)
    capture_io do
      begin
        Tallmadge::CLI.start(args)
      rescue SystemExit
        nil
      end
    end
  end

  def user_mcp_json
    JSON.parse(File.read(home(".tallmadge", "profiles", "default", "mcp.json")))
  end

  def composed_mcp_json
    JSON.parse(File.read(agents("mcp.json")))
  end

  def add_server(name, command = %w[npx pkg], **opts)
    capture_io { Tallmadge::Mcp.add(state, name, command, **opts) }
  end

  def test_stdio_add_writes_user_copy_and_composes
    out, = add_server("gh", %w[npx -y pkg], env: ["TOKEN=abc"])
    assert_match(/added mcp server gh/, out)

    user = user_mcp_json["mcpServers"]["gh"]
    assert_equal "npx", user["command"]
    assert_equal ["-y", "pkg"], user["args"]
    assert_equal({ "TOKEN" => "abc" }, user["env"])
    refute user.key?("type") # stdio shape external harnesses already use

    assert_equal user, composed_mcp_json["mcpServers"]["gh"]
    assert_equal "user", state.mcp_origins["gh"]
  end

  def test_url_add_defaults_to_http_and_supports_sse
    add_server("remote", [], url: "https://example.com/mcp")
    assert_equal({ "type" => "http", "url" => "https://example.com/mcp" },
                 composed_mcp_json["mcpServers"]["remote"])

    add_server("events", [], url: "https://example.com/sse", transport: "sse")
    assert_equal "sse", composed_mcp_json["mcpServers"]["events"]["type"]

    err = assert_raises(Tallmadge::Error) { add_server("bad", [], url: "https://x", transport: "ws") }
    assert_match(/--transport must be http or sse/, err.message)
  end

  def test_config_add_is_verbatim_with_object_check
    raw = '{"type":"http","url":"https://x.example","headers":{"A":"b"}}'
    add_server("custom", [], config: raw)
    assert_equal JSON.parse(raw), composed_mcp_json["mcpServers"]["custom"]

    err = assert_raises(Tallmadge::Error) { add_server("bad", [], config: "{nope") }
    assert_match(/invalid --config JSON/, err.message)
    err = assert_raises(Tallmadge::Error) { add_server("bad", [], config: "[1,2]") }
    assert_match(/--config must be a JSON object/, err.message)
  end

  def test_add_mode_conflicts_raise
    err = assert_raises(Tallmadge::Error) { add_server("x", %w[cmd], url: "https://x") }
    assert_match(/--url cannot be combined with a command/, err.message)

    err = assert_raises(Tallmadge::Error) { add_server("x", %w[cmd], config: "{}") }
    assert_match(/--config cannot be combined/, err.message)

    err = assert_raises(Tallmadge::Error) { add_server("x", %w[cmd], env: ["A=b"], config: "{}") }
    assert_match(/--config cannot be combined/, err.message)

    err = assert_raises(Tallmadge::Error) { add_server("x", [], env: ["A=b"], url: "https://x") }
    assert_match(/--url cannot be combined/, err.message)

    err = assert_raises(Tallmadge::Error) { add_server("x", [], env: ["BAD"], url: "https://x") }
    assert_match(/invalid --env value/, err.message)
  end

  def test_duplicate_add_raises_with_hints
    add_server("gh")
    err = assert_raises(Tallmadge::Error) { add_server("gh", %w[other cmd]) }
    assert_match(/already exists in your user config/, err.message)
    assert_match(/clpr mcp remove gh/, err.message)

    install_plugin("demo", '{"mcpServers":{"demo-srv":{"command":"echo"}}}')
    err = assert_raises(Tallmadge::Error) { add_server("demo-srv") }
    assert_match(/already provided by plugin demo/, err.message)
  end

  def test_invalid_name_and_missing_mode_raise
    err = assert_raises(Tallmadge::Error) { add_server("bad name") }
    assert_match(/invalid mcp server name 'bad name'/, err.message)

    err = assert_raises(Tallmadge::Error) { add_server("-leading-dash") }
    assert_match(/invalid mcp server name/, err.message)

    err = assert_raises(Tallmadge::Error) { add_server("x" * 65) }
    assert_match(/max 64 chars/, err.message)

    err = assert_raises(Tallmadge::Error) { add_server("ok", []) }
    assert_match(/pass a command .* --url URL, or --config JSON/, err.message)
  end

  def test_remove_user_server_keeps_others_and_last_remove_deletes_composed_file
    add_server("one", %w[cmd1])
    add_server("two", %w[cmd2])

    out, = capture_io { Tallmadge::Mcp.remove(state, "one") }
    assert_match(/removed mcp server one/, out)
    composed = composed_mcp_json
    refute composed["mcpServers"].key?("one")
    assert composed["mcpServers"].key?("two")

    capture_io { Tallmadge::Mcp.remove(state, "two") }
    refute File.exist?(agents("mcp.json"))
  end

  def test_remove_plugin_provided_raises_deactivate_hint
    install_plugin("demo", '{"mcpServers":{"demo-srv":{"command":"echo"}}}')
    err = assert_raises(Tallmadge::Error) { Tallmadge::Mcp.remove(state, "demo-srv") }
    assert_match(/provided by plugin demo/, err.message)
    assert_match(/deactivate it instead/, err.message)

    err = assert_raises(Tallmadge::Error) { Tallmadge::Mcp.remove(state, "nope") }
    assert_match(/no mcp server named 'nope'/, err.message)
  end

  def test_deactivate_and_activate_user_server
    add_server("gh")
    add_server("other", %w[cmd])

    capture_io { Tallmadge::Mcp.deactivate(state, "gh") }
    composed = composed_mcp_json
    refute composed["mcpServers"].key?("gh")
    assert composed["mcpServers"].key?("other")

    assert_equal ["gh"], state.mcp_disabled # persists across a fresh load

    out, = capture_io { Tallmadge::Mcp.deactivate(state, "gh") }
    assert_match(/already inactive/, out)

    capture_io { Tallmadge::Mcp.activate(state, "gh") }
    assert composed_mcp_json["mcpServers"].key?("gh")
    assert_empty state.mcp_disabled

    out, = capture_io { Tallmadge::Mcp.activate(state, "gh") }
    assert_match(/already active/, out)
  end

  def test_activate_and_deactivate_plugin_server_by_name
    install_plugin("demo", '{"mcpServers":{"demo-srv":{"command":"echo"}}}')

    out, = capture_io { Tallmadge::Mcp.activate(state, "demo-srv") }
    assert_match(/activated demo/, out)
    assert composed_mcp_json["mcpServers"].key?("demo-srv")
    assert_equal "demo", state.mcp_origins["demo-srv"]
    refute File.symlink?(agents("skills", "hello")) # mcp only — no component links

    capture_io { Tallmadge::Mcp.deactivate(state, "demo-srv") }
    refute File.exist?(agents("mcp.json")) # last server gone -> composed file removed
    refute state.mcp_origins.key?("demo-srv")
  end

  def test_ambiguous_plugin_server_name_raises
    install_plugin("a", '{"mcpServers":{"shared":{"command":"echo"}}}')
    install_plugin("b", '{"mcpServers":{"shared":{"command":"echo"}}}')

    err = assert_raises(Tallmadge::Error) { Tallmadge::Mcp.activate(state, "shared") }
    assert_match(/multiple plugins: a, b/, err.message)
    assert_match(/clpr activate <plugin> --mcp shared/, err.message)
  end

  def test_list_prints_user_and_plugin_rows
    install_plugin("demo", '{"mcpServers":{"demo-srv":{"command":"echo"}}}')
    add_server("gh")
    capture_io { Tallmadge::Mcp.activate(state, "demo-srv") }
    capture_io { Tallmadge::Mcp.deactivate(state, "gh") }

    out, = capture_io { Tallmadge::Mcp.list(state) }
    assert_match(/^\s*gh\s+user\s+stdio\s+inactive/, out)
    assert_match(/^\s*demo-srv\s+demo\s+stdio\s+active/, out)
  end

  def test_list_empty_state_prints_info
    out, = capture_io { Tallmadge::Mcp.list(state) }
    assert_match(/no mcp servers configured/, out)
  end

  def test_get_prints_config_origin_and_status
    add_server("gh", %w[npx -y pkg], env: ["A=b"])

    out, = capture_io { Tallmadge::Mcp.get(state, "gh") }
    assert_includes out, "name: gh"
    assert_includes out, "origin: user"
    assert_includes out, "active: true"
    assert_includes out, '"command": "npx"'
    assert_includes out, '"A": "b"'

    err = assert_raises(Tallmadge::Error) { Tallmadge::Mcp.get(state, "nope") }
    assert_match(/no mcp server named 'nope'/, err.message)
    assert_match(/available: gh/, err.message)
  end

  def test_cli_activate_mcp_filter_composes_without_links
    install_plugin("demo", '{"mcpServers":{"demo-srv":{"command":"echo"}}}')

    run_cli("activate", "demo", "--mcp", "demo-srv")
    assert composed_mcp_json["mcpServers"].key?("demo-srv")
    refute File.symlink?(agents("skills", "hello"))
    assert state.profile_plugins.dig("demo", "components", "mcpServers", "demo-srv", "active")
    refute state.profile_plugins.dig("demo", "components", "skills", "hello", "active")

    run_cli("deactivate", "demo", "--mcp", "demo-srv")
    refute File.exist?(agents("mcp.json"))
  end

  def test_cli_add_proves_env_hash_and_dash_dash_passthrough
    out, = run_cli("mcp", "add", "gh", "--env", "K=V", "--", "npx", "-y", "pkg")
    assert_match(/added mcp server gh/, out)

    user = user_mcp_json["mcpServers"]["gh"]
    assert_equal({"K" => "V"}, user["env"])
    assert_equal ["-y", "pkg"], user["args"]

    assert_equal user, composed_mcp_json["mcpServers"]["gh"]
  end
end
