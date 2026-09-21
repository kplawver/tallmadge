# frozen_string_literal: true

require_relative "test_helper"

class RepoTest < Minitest::Test
  include TallmadgeTestHelpers

  # Build a throwaway git repo with the canonical .agents layout and the
  # given harness config dirs (e.g. %w[.claude .cursor]).
  def fixture_repo(harnesses: %w[.claude .cursor], agents: true)
    root = home("fixture-repo")
    FileUtils.mkdir_p(File.join(root, ".git"))
    write File.join(root, "AGENTS.md"), "# Standards\n"
    write File.join(root, ".agents", "skills", "x", "SKILL.md"), skill_md(name: "x")
    if agents
      write File.join(root, ".agents", "agents", "reviewer", "agent.md"),
            "---\nname: reviewer\ndescription: reviews code\n---\nBody\n"
    end
    harnesses.each { |h| FileUtils.mkdir_p(File.join(root, h)) }
    root
  end

  def run_repo_check(root)
    capture_io { Tallmadge::Repo.check(root) }
  end

  def run_repo_link(root, **kwargs)
    capture_io { Tallmadge::Repo.link(root, **kwargs) }
  end

  def test_check_reports_missing_bridges
    root = fixture_repo

    out, = run_repo_check(root)
    assert_match(/CLAUDE\.md missing/, out)
    assert_match(%r{\.claude/skills missing}, out)
    assert_match(%r{\.cursor/agents missing}, out)
    assert_match(/0 error\(s\), /, out) # missing bridges are warnings
  end

  def test_check_conflict_is_error_and_never_touched
    root = fixture_repo
    conflict = File.join(root, ".claude", "skills")
    write File.join(conflict, "own-skill", "SKILL.md"), "mine\n"
    before = Dir.children(conflict)

    out, = run_repo_check(root)
    assert_match(%r{claude: \.claude/skills exists but is not the expected symlink}, out)
    assert_match(/1 error\(s\), /, out)

    # --execute must leave the conflicting dir byte-identical.
    run_repo_link(root, execute: true)
    assert_equal before, Dir.children(conflict)
    assert_equal "mine\n", File.read(File.join(conflict, "own-skill", "SKILL.md"))
    refute File.symlink?(conflict)
  end

  def test_link_dry_run_creates_nothing
    root = fixture_repo

    out, = run_repo_link(root)
    assert_match(/would create/, out)
    [File.join(root, "CLAUDE.md"),
     File.join(root, ".claude", "skills"),
     File.join(root, ".claude", "agents"),
     File.join(root, ".cursor", "agents")].each do |path|
      refute File.symlink?(path), "#{path} should not exist after dry run"
      refute File.exist?(path), "#{path} should not exist after dry run"
    end
  end

  def test_link_execute_creates_relative_symlinks
    root = fixture_repo

    run_repo_link(root, execute: true)

    assert File.symlink?(File.join(root, "CLAUDE.md"))
    assert_equal "AGENTS.md", File.readlink(File.join(root, "CLAUDE.md"))
    assert_equal "../.agents/skills", File.readlink(File.join(root, ".claude", "skills"))
    assert_equal "../.agents/agents", File.readlink(File.join(root, ".claude", "agents"))
    assert_equal "../.agents/agents", File.readlink(File.join(root, ".cursor", "agents"))
    assert_equal "# Standards\n", File.read(File.join(root, "CLAUDE.md"))
  end

  def test_link_execute_is_idempotent
    root = fixture_repo

    run_repo_link(root, execute: true)
    links = Dir[File.join(root, "**", "*")].select { |p| File.symlink?(p) }
    out, = run_repo_link(root, execute: true)
    assert_match(/already ok/, out)
    refute_match(/linked /, out)
    assert_equal links.size, Dir[File.join(root, "**", "*")].select { |p| File.symlink?(p) }.size
  end

  def test_link_single_harness_flag
    root = fixture_repo(harnesses: %w[.claude])

    run_repo_link(root, harnesses: "gemini", execute: true)

    assert_equal "../.agents/agents", File.readlink(File.join(root, ".gemini", "agents"))
    assert_equal "AGENTS.md", File.readlink(File.join(root, "GEMINI.md"))
    refute File.exist?(File.join(root, ".claude", "skills"))
    refute File.exist?(File.join(root, "CLAUDE.md"))
  end

  def test_copilot_per_agent_flat_links
    root = fixture_repo(harnesses: %w[.github/agents])
    write File.join(root, ".agents", "agents", "writer.md"),
          "---\nname: writer\ndescription: writes\n---\nBody\n"

    run_repo_link(root, execute: true)

    reviewer = File.join(root, ".github", "agents", "reviewer.agent.md")
    writer = File.join(root, ".github", "agents", "writer.agent.md")
    assert File.symlink?(reviewer)
    assert File.symlink?(writer)
    assert_equal "../../.agents/agents/reviewer/agent.md", File.readlink(reviewer)
    assert_equal "../../.agents/agents/writer.md", File.readlink(writer)
  end

  def test_check_invalid_frontmatter_is_error
    root = fixture_repo
    write File.join(root, ".agents", "skills", "broken", "SKILL.md"),
          "---\nname: broken\n---\nNo description\n"

    out, = run_repo_check(root)
    assert_match(/broken\/SKILL\.md: missing description frontmatter/, out)
    assert_match(/1 error\(s\), /, out)
  end

  def test_check_detects_reverse_canonical_pattern
    root = fixture_repo(harnesses: %w[.claude])
    File.unlink(File.join(root, "AGENTS.md"))
    File.write(File.join(root, "CLAUDE.md"), "# Standards\n")
    File.symlink("CLAUDE.md", File.join(root, "AGENTS.md"))

    out, = run_repo_check(root)
    assert_match(/AGENTS\.md → CLAUDE\.md \(canonical: CLAUDE\.md\)/, out)
    refute_match(/CLAUDE\.md missing/, out)
    assert_match(/0 error\(s\), /, out)
  end

  def test_check_not_a_git_repo_raises
    plain = home("plain")
    FileUtils.mkdir_p(plain)

    error = assert_raises(Tallmadge::Error) { capture_io { Tallmadge::Repo.check(plain) } }
    assert_match(/not a git repository/, error.message)
  end

  def test_unknown_harness_id_raises
    root = fixture_repo

    error = assert_raises(Tallmadge::Error) { Tallmadge::Repo.plan(root, ["bogus"]) }
    assert_match(/unknown harness 'bogus'/, error.message)
    assert_match(/claude, cursor/, error.message)

    error = assert_raises(Tallmadge::Error) { run_repo_link(root, harnesses: "bogus") }
    assert_match(/unknown harness 'bogus'/, error.message)
  end

  def test_check_reports_unbridgeable_harnesses_info
    root = fixture_repo(harnesses: %w[.codex])
    write File.join(root, ".codex", "agents", "foo.toml"), "name = 'foo'\n"

    out, = run_repo_check(root)
    assert_match(/codex: agents are TOML in \.codex\/agents — maintain manually/, out)
  end

  def test_cli_check_happy_path
    root = fixture_repo

    out, = capture_io do
      begin
        Tallmadge::CLI.start(["repo", "check", root])
      rescue SystemExit
        nil
      end
    end
    assert_match(/== instructions ==/, out)
    assert_match(/== harness bridges ==/, out)

    Tallmadge::Repo.link(root, execute: true)
    out, = capture_io do
      begin
        Tallmadge::CLI.start(["repo", "check", root])
      rescue SystemExit => e
        assert_equal 0, e.status
      end
    end
    assert_match(/CLAUDE\.md → AGENTS\.md/, out)
  end

  def test_cli_link_dry_run_and_execute
    root = fixture_repo

    out, = capture_io do
      begin
        Tallmadge::CLI.start(["repo", "link", root])
      rescue SystemExit
        nil
      end
    end
    assert_match(/would create/, out)
    refute File.symlink?(File.join(root, "CLAUDE.md"))

    capture_io do
      begin
        Tallmadge::CLI.start(["repo", "link", root, "--execute"])
      rescue SystemExit
        nil
      end
    end
    assert File.symlink?(File.join(root, "CLAUDE.md"))
  end

  def test_check_reports_each_instruction_alias_exactly_once
    root = fixture_repo
    run_repo_link(root, execute: true)

    out, = run_repo_check(root)
    assert_equal 1, out.scan(/CLAUDE\.md/).size
    assert_equal 1, out.scan(/✓ CLAUDE\.md → AGENTS\.md/).size
  end

  def test_link_with_no_detected_harnesses_is_info_not_error
    root = fixture_repo(harnesses: [])

    out, = run_repo_link(root, execute: true)
    assert_match(/no supported harness detected/, out)
    assert_match(/--harness ID/, out)
    refute File.exist?(File.join(root, "CLAUDE.md"))
  end
end
