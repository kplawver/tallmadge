# frozen_string_literal: true

require_relative "test_helper"

class EditorTest < Minitest::Test
  include TallmadgeTestHelpers

  def stub_open
    @opened_path = nil
    Tallmadge::Editor.stub :open_with_default_app, ->(path) { @opened_path = path } do
      yield
    end
  end

  def test_edit_creates_missing_agents_md_and_registers_it
    stub_open do
      out, = capture_io do
        Tallmadge::Editor.edit(state, "agents.md")
      end
      assert_match(/created/, out)
    end

    path = home(".tallmadge", "profiles", "default", "agents.md")
    assert File.exist?(path), "user agents.md should be created"
    assert_equal @opened_path, path
    assert_equal "profiles/default/agents.md", state.user_content["agentsMd"]
  end

  def test_edit_creates_mcp_json_with_parseable_seed
    stub_open do
      capture_io { Tallmadge::Editor.edit(state, "mcp.json") }
    end

    path = home(".tallmadge", "profiles", "default", "mcp.json")
    assert File.exist?(path)
    assert_equal({ "mcpServers" => {} }, JSON.parse(File.read(path)))
    assert_equal "profiles/default/mcp.json", state.user_content["mcpJson"]
  end

  def test_edit_matches_filename_case_insensitively
    stub_open do
      capture_io { Tallmadge::Editor.edit(state, "AGENTS.MD") }
    end
    assert File.exist?(home(".tallmadge", "profiles", "default", "agents.md"))
  end

  def test_edit_rejects_unknown_file
    error = assert_raises(Tallmadge::Error) do
      capture_io { Tallmadge::Editor.edit(state, "README.md") }
    end
    assert_match(/editable files: agents\.md, mcp\.json/, error.message)
  end

  def test_edit_opens_existing_file_without_touching_it
    s = state
    Tallmadge::Editor.ensure_user_file!(s, "agentsMd", "agents.md")
    path = home(".tallmadge", "profiles", "default", "agents.md")
    File.write(path, "MY NOTES\n")

    stub_open do
      out, = capture_io { Tallmadge::Editor.edit(s, "agents.md") }
      assert_match(/opened/, out)
      refute_match(/created/, out)
    end

    assert_equal "MY NOTES\n", File.read(path)
  end

  def test_edit_recreates_missing_file_at_legacy_location
    s = state
    s.user_content["agentsMd"] = "store/user/agents.md"
    s.save

    stub_open do
      out, = capture_io { Tallmadge::Editor.edit(s, "agents.md") }
      assert_match(/recreated missing/, out)
    end

    legacy = store("user", "agents.md")
    assert File.exist?(legacy)
    # Legacy registration is preserved, not migrated behind the user's back.
    assert_equal "store/user/agents.md", state.user_content["agentsMd"]
  end

  def test_created_agents_md_flows_into_composed_file
    s = state
    Tallmadge::Editor.ensure_user_file!(s, "agentsMd", "agents.md")
    File.write(home(".tallmadge", "profiles", "default", "agents.md"), "USER CONTENT\n")

    capture_io { Tallmadge::Activator.new(s).compose_agents_md! }

    composed = File.read(agents("agents.md"))
    assert_includes composed, "<!-- managed by tallmadge -->"
    assert_includes composed, "USER CONTENT"
  end

  def test_opener_targets_the_file_on_this_platform
    assert_includes Tallmadge::Editor.opener("/tmp/some-file.md"), "/tmp/some-file.md"
  end

  def test_open_failure_raises_error
    Tallmadge::Editor.stub :opener, ["false"] do
      error = assert_raises(Tallmadge::Error) do
        capture_io { Tallmadge::Editor.open_with_default_app("/tmp/nope.md") }
      end
      assert_match(/could not open/, error.message)
    end
  end

  def test_missing_opener_binary_raises_error
    Tallmadge::Editor.stub :opener, ["definitely-not-a-real-command-xyz"] do
      error = assert_raises(Tallmadge::Error) do
        capture_io { Tallmadge::Editor.open_with_default_app("/tmp/nope.md") }
      end
      assert_match(/could not open/, error.message)
    end
  end
end
