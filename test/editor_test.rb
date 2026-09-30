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

  def run_cli_with_stdin(input, *args)
    $stdin = StringIO.new(input)
    capture_io do
      Tallmadge::CLI.start(args)
    rescue SystemExit
      nil
    end
  ensure
    $stdin = STDIN
  end

  def test_uninstall_with_user_skills_among_ids_aborts_before_removing_anything
    write(home("fixture", "skills", "theirs", "SKILL.md"), skill_md(name: "theirs"))
    capture_io do
      Tallmadge::Installer.new(state).install_path(home("fixture"), as: "vendor")
      Tallmadge::Skills.create_user_skill!(state, "mine")
    end

    run_cli_with_stdin("n\n", "uninstall", "vendor", "user-skills")

    assert Dir.exist?(store("vendor"))
    assert Dir.exist?(store("user-skills"))
  end

  def test_uninstall_with_no_answer_keeps_user_skills
    capture_io { Tallmadge::Skills.create_user_skill!(state, "mine") }

    run_cli_with_stdin("", "uninstall", "user-skills")

    assert Dir.exist?(store("user-skills"))
  end

  def test_creating_and_deleting_skills_never_warns_about_agents_md
    out, err = capture_io do
      %w[one two three].each { |name| Tallmadge::Skills.create_user_skill!(state, name) }
      Tallmadge::Skills.delete_user_skill!(state, "two")
    end

    refute_match(/agents\.md/, out + err)
  end

  def test_delete_removes_only_the_named_user_skill
    capture_io do
      Tallmadge::Skills.create_user_skill!(state, "keep")
      Tallmadge::Skills.create_user_skill!(state, "drop")
      Tallmadge::Skills.delete_user_skill!(state, "drop")
    end

    refute File.exist?(store("user-skills", "skills", "drop"))
    refute File.symlink?(agents("skills", "drop"))
    assert File.symlink?(agents("skills", "keep"))
    assert_equal %w[keep], Tallmadge::Skills.user_skill_names(state)
  end

  def test_delete_rejects_skills_not_created_by_the_user
    write(home("fixture", "skills", "theirs", "SKILL.md"), skill_md(name: "theirs"))
    capture_io { Tallmadge::Installer.new(state).install_path(home("fixture"), as: "vendor") }

    error = assert_raises(Tallmadge::Error) { Tallmadge::Skills.delete_user_skill!(state, "theirs") }
    assert_match(/no skill you created/, error.message)
    assert File.exist?(store("vendor", "skills", "theirs", "SKILL.md"))
  end

  def test_uninstall_user_skills_warns_and_aborts_unless_confirmed
    capture_io { Tallmadge::Skills.create_user_skill!(state, "mine") }

    out, err = run_cli_with_stdin("n\n", "uninstall", "user-skills")
    assert_match(/deletes them permanently/, out + err)
    assert File.exist?(store("user-skills", "skills", "mine", "SKILL.md"))

    run_cli_with_stdin("y\n", "uninstall", "user-skills")
    refute Dir.exist?(store("user-skills"))
  end

  def test_uninstall_user_skills_with_yes_skips_the_warning
    capture_io { Tallmadge::Skills.create_user_skill!(state, "mine") }

    out, err = run_cli_with_stdin("", "uninstall", "user-skills", "--yes")
    refute_match(/permanently/, out + err)
    refute Dir.exist?(store("user-skills"))
  end

  def test_new_skill_is_scaffolded_activated_and_tracked_as_user_owned
    stub_open do
      capture_io { Tallmadge::CLI.start(["skill", "new", "my-skill", "-d", "Does: things"]) }
    end

    skill_file = store("user-skills", "skills", "my-skill", "SKILL.md")
    assert_equal skill_file, @opened_path
    frontmatter = File.read(skill_file)[/\A---\n(.*?)\n---/m, 1]
    assert_equal "Does: things", YAML.safe_load(frontmatter)["description"]
    assert_equal({ "type" => "user" }, state.plugins["user-skills"]["source"])
    assert File.symlink?(agents("skills", "my-skill"))
    assert state.profile_plugins.dig("user-skills", "components", "skills", "my-skill", "active")
  end

  def test_second_new_skill_keeps_first_active
    stub_open do
      capture_io do
        Tallmadge::CLI.start(["skill", "new", "first"])
        Tallmadge::CLI.start(["skill", "new", "second"])
      end
    end

    assert File.symlink?(agents("skills", "first"))
    assert File.symlink?(agents("skills", "second"))
  end

  def test_new_skill_rejects_bad_and_duplicate_names
    assert_raises(Tallmadge::Error) { Tallmadge::Skills.create_user_skill!(state, "Bad Name") }

    capture_io { Tallmadge::Skills.create_user_skill!(state, "dup") }
    error = assert_raises(Tallmadge::Error) { Tallmadge::Skills.create_user_skill!(state, "dup") }
    assert_match(/already exists/, error.message)
  end

  def test_edit_opens_user_skill_by_name
    capture_io { Tallmadge::Skills.create_user_skill!(state, "my-skill") }

    stub_open do
      capture_io { Tallmadge::Editor.edit(state, "my-skill") }
    end

    assert_equal store("user-skills", "skills", "my-skill", "SKILL.md"), @opened_path
  end

  def test_install_force_cannot_overwrite_user_skills
    capture_io { Tallmadge::Skills.create_user_skill!(state, "mine") }
    write(home("fixture", "SKILL.md"), skill_md)

    error = assert_raises(Tallmadge::Error) do
      capture_io { Tallmadge::Installer.new(state).install_path(home("fixture"), as: "user-skills", force: true) }
    end
    assert_match(/erase them/, error.message)
    assert File.exist?(store("user-skills", "skills", "mine", "SKILL.md"))
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
