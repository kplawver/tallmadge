# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Minitest::Test
  include TallmadgeTestHelpers

  def install_plugin(id, skill_names)
    dir = home("fixture", id)
    skill_names.each { |s| write(File.join(dir, "skills", s, "SKILL.md"), skill_md(name: s)) }
    capture_io { Tallmadge::Installer.new(state).install_path(dir, as: id) }
  end

  # CLI.start rescues Tallmadge::Error into Reporter.err + exit(1), so a
  # failing command surfaces as SystemExit — never let it kill the run.
  def run_cli(*args)
    capture_io do
      # Modifier rescue won't do: SystemExit is not a StandardError.
      begin
        Tallmadge::CLI.start(args)
      rescue SystemExit
        nil
      end
    end
  end

  def test_activate_and_deactivate_accept_multiple_ids
    install_plugin("alpha", %w[one])
    install_plugin("beta", %w[two])
    install_plugin("gamma", %w[three])

    run_cli("activate", "alpha", "beta")
    assert File.symlink?(agents("skills", "one"))
    assert File.symlink?(agents("skills", "two"))
    refute File.symlink?(agents("skills", "three"))

    run_cli("deactivate", "alpha", "beta")
    refute File.symlink?(agents("skills", "one"))
    refute File.symlink?(agents("skills", "two"))
  end

  def test_uninstall_accepts_multiple_ids
    install_plugin("alpha", %w[one])
    install_plugin("beta", %w[two])

    run_cli("activate", "alpha", "beta")
    out, = run_cli("uninstall", "alpha", "beta")
    assert_match(/uninstalled alpha/, out)
    assert_match(/uninstalled beta/, out)

    s = state
    refute s.plugins.key?("alpha")
    refute s.plugins.key?("beta")
    refute Dir.exist?(store("alpha"))
    refute Dir.exist?(store("beta"))
  end

  def test_component_commands_without_ids_fail_with_usage_error
    %w[activate deactivate uninstall].each do |cmd|
      out, = capture_io do
        assert_raises(SystemExit) { Tallmadge::CLI.start([cmd]) }
      end
      assert_match(/no plugin id given/, out, "#{cmd} should report missing id")
    end
  end

  def test_activate_with_component_filter_applies_to_all_ids
    install_plugin("alpha", %w[shared other-a])
    install_plugin("beta", %w[shared other-b])

    # Both plugins ship a "shared" skill: alpha wins the name, beta's copy
    # conflicts (first-come; --force would back it up).
    out, = run_cli("activate", "alpha", "beta", "--skill", "shared")
    assert File.symlink?(agents("skills", "shared"))
    refute File.symlink?(agents("skills", "other-a"))
    refute File.symlink?(agents("skills", "other-b"))
    assert_match(/already exists and is not a tallmadge link for beta/, out)

    s = state
    assert s.profile_plugins.dig("alpha", "components", "skills", "shared", "active")
    refute s.profile_plugins.dig("beta", "components", "skills", "shared", "active")
  end
end
