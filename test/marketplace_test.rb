# frozen_string_literal: true

require_relative "test_helper"

class MarketplaceTest < Minitest::Test
  include TallmadgeTestHelpers

  def test_classify_sources
    m = Tallmadge::Marketplace
    assert_equal :github, m.classify("owner/repo")
    assert_equal :git, m.classify("https://example.com/x.git")
    assert_equal :git, m.classify("git@github.com:owner/repo.git")
    assert_equal :git, m.classify("https://example.com/repo")
    assert_equal :url, m.classify("https://example.com/catalog.json")
    assert_equal :path, m.classify("./local/dir")
    assert_equal :path, m.classify("/abs/dir")
  end

  def test_classify_rejects_unknown
    assert_raises(Tallmadge::Error) { Tallmadge::Marketplace.classify("") }
  end

  def test_validate_catalog_failures
    m = Tallmadge::Marketplace
    assert_raises(Tallmadge::Error) do
      m.validate_catalog!({ "name" => "Bad Name!", "owner" => { "name" => "x" },
                            "plugins" => [] }, "t")
    end
    assert_raises(Tallmadge::Error) do
      m.validate_catalog!({ "name" => "ok", "plugins" => [] }, "t") # missing owner
    end
    assert_raises(Tallmadge::Error) do
      m.validate_catalog!({ "name" => "ok", "owner" => { "name" => "x" } }, "t") # no plugins
    end
    assert_raises(Tallmadge::Error) do
      m.validate_catalog!({ "name" => "x" * 65, "owner" => { "name" => "x" },
                            "plugins" => [] }, "t") # name too long
    end
  end

  def test_valid_entries_skips_invalid_with_warning
    catalog = {
      "name" => "t",
      "plugins" => [
        { "name" => "good", "source" => "./x" },
        { "name" => "no-source" },
        { "source" => "./y" },
        "garbage"
      ]
    }
    out, = capture_io { @entries = Tallmadge::Marketplace.valid_entries(catalog) }
    assert_equal ["good"], @entries.map { |e| e["name"] }
    assert_match(/skipping invalid/, out)
  end

def test_add_path_marketplace_installs_plugins_with_plugin_root
  mp_dir = home("mp")
  write File.join(mp_dir, ".claude-plugin", "marketplace.json"), JSON.generate(
    "name" => "fixture",
    "owner" => { "name" => "t" },
    "metadata" => { "pluginRoot" => "plugins" },
    "plugins" => [{ "name" => "demo", "source" => "./demo", "version" => "2.0.0" }]
  )
  write File.join(mp_dir, "plugins", "demo", "skills", "hi", "SKILL.md"),
        skill_md(name: "hi")

  capture_io { Tallmadge::Marketplace.add(state, mp_dir) }
  st = state
  assert st.marketplaces.key?("fixture")
  assert_equal "path", st.marketplaces["fixture"].dig("source", "type")

  # Plugin auto-installed by marketplace add — no separate `install` needed
  entry = st.plugins["demo@fixture"]
  refute_nil entry
  assert_equal "2.0.0", entry.dig("source", "version")
  assert_equal "marketplace", entry.dig("source", "type")
  assert Dir.exist?(store("demo@fixture", "skills", "hi"))
end

  def test_add_requires_catalog
    bare = home("bare")
    write File.join(bare, "README.md"), "no catalog here"
    err = assert_raises(Tallmadge::Error) do
      capture_io { Tallmadge::Marketplace.add(state, bare) }
    end
    assert_match(/no marketplace.json/, err.message)
  end

  def test_add_same_marketplace_includes_in_profile
    mp_dir = home("mp")
    write File.join(mp_dir, ".claude-plugin", "marketplace.json"), JSON.generate(
      "name" => "fixture", "owner" => { "name" => "t" },
      "plugins" => [{ "name" => "demo", "source" => "./" }]
    )
    capture_io { Tallmadge::Marketplace.add(state, mp_dir) }
    out, = capture_io { Tallmadge::Marketplace.add(state, mp_dir) }
    assert_match(/already added; included in profile default/, out)
  end

  def test_install_unknown_plugin_at_marketplace
    mp_dir = home("mp")
    write File.join(mp_dir, ".claude-plugin", "marketplace.json"), JSON.generate(
      "name" => "fixture", "owner" => { "name" => "t" },
      "plugins" => [{ "name" => "demo", "source" => "./" }]
    )
    capture_io { Tallmadge::Marketplace.add(state, mp_dir) }
    err = assert_raises(Tallmadge::Error) do
      capture_io { Tallmadge::Installer.new(state).install("missing@fixture") }
    end
    assert_match(/not found/, err.message)
  end

  def test_remove_marketplace_keeps_installed_plugins
    mp_dir = home("mp")
    write File.join(mp_dir, ".claude-plugin", "marketplace.json"), JSON.generate(
      "name" => "fixture", "owner" => { "name" => "t" },
      "plugins" => [{ "name" => "demo", "source" => "./" }]
    )
    write File.join(mp_dir, "skills", "s", "SKILL.md"), skill_md
    capture_io { Tallmadge::Marketplace.add(state, mp_dir) }

    capture_io { Tallmadge::Marketplace.remove(state, "fixture") }
    st = state
    refute st.marketplaces.key?("fixture")
    assert st.plugins.key?("demo@fixture") # plugin survives
  end

  def test_marketplace_add_auto_installs_and_enables_activation
    mp_dir = home("mp")
    write File.join(mp_dir, ".claude-plugin", "marketplace.json"), JSON.generate(
      "name" => "fixture", "owner" => { "name" => "t" },
      "plugins" => [{ "name" => "demo", "source" => "./demo" }]
    )
    write File.join(mp_dir, "demo", "skills", "greet", "SKILL.md"),
          skill_md(name: "greet")

    capture_io { Tallmadge::Marketplace.add(state, mp_dir) }
    st = state

    # Plugin shows up in state.plugins (i.e. `clpr list` would show it)
    assert st.plugins.key?("demo@fixture")
    assert st.profile_plugins.key?("demo@fixture")

    # Plugin can be activated immediately — no separate `install` step
    capture_io { Tallmadge::Activator.new(st).activate("demo@fixture") }
    assert File.symlink?(agents("skills", "greet"))
  end

  def test_marketplace_add_auto_install_skips_already_installed
    mp_dir = home("mp")
    write File.join(mp_dir, ".claude-plugin", "marketplace.json"), JSON.generate(
      "name" => "fixture", "owner" => { "name" => "t" },
      "plugins" => [{ "name" => "demo", "source" => "./demo" }]
    )
    write File.join(mp_dir, "demo", "skills", "greet", "SKILL.md"),
          skill_md(name: "greet")

    # First add installs the plugin
    capture_io { Tallmadge::Marketplace.add(state, mp_dir) }
    st = state
    assert st.plugins.key?("demo@fixture")

    # Second add (already added) should not error — just ensures profile inclusion
    out = capture_io { Tallmadge::Marketplace.add(state, mp_dir) }.join
    assert_match(/already added/, out)
  end
end
