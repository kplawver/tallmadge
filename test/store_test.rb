# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  include HandlrTestHelpers

  def test_derive_id_sanitizes
    assert_equal "demo", Handlr::Store.derive_id("https://github.com/owner/Demo.git")
    assert_equal "demo", Handlr::Store.derive_id("/tmp/Demo/")
    assert_equal "my-plugin", Handlr::Store.derive_id("~/My Plugin")
    assert_equal "repo", Handlr::Store.derive_id("owner/Repo")
  end

  def test_derive_id_requires_nonempty
    assert_raises(Handlr::Error) { Handlr::Store.derive_id("///") }
  end

  def test_scan_full_tree
    dir = home("fixture", "demo")
    write File.join(dir, "skills", "s1", "SKILL.md"), skill_md(name: "s1")
    write File.join(dir, "skills", "s2", "skill.md"), skill_md(name: "s2") # case-insensitive
    write File.join(dir, "agents", "a1", "agent.md"), "---\nname: a1\n---\nAgent\n"
    write File.join(dir, "agents", "flat.md"), "---\nname: flat\n---\nFlat agent\n"
    write File.join(dir, "tasks", "t1", "task.md"), "---\nkind: task\n---\nDo\n"
    write File.join(dir, "memories", "m1.md"), "memory one"
    write File.join(dir, "mcp.json"), '{"mcpServers":{"srv":{"command":"x"}}}'
    write File.join(dir, "AGENTS.md"), "instructions"

    components = Handlr::Store.scan_components(dir)
    assert_equal %w[s1 s2], components["skills"].keys.sort
    assert_equal %w[a1 flat], components["agents"].keys.sort
    assert_equal %w[t1], components["tasks"].keys
    assert_equal %w[m1.md], components["memories"].keys
    assert_equal %w[srv], components["mcpServers"].keys
    assert_equal false, components["agentsMd"]["active"]
    assert_equal({ "active" => false }, components["skills"]["s1"])
  end

  def test_scan_root_skill_md_named_after_dir
    dir = home("fixture", "rooty")
    write File.join(dir, "SKILL.md"), skill_md(name: "rooty")
    components = Handlr::Store.scan_components(dir)
    assert_equal ["rooty"], components["skills"].keys
  end

  def test_scan_prefers_skills_dir_over_root_skill
    dir = home("fixture", "mixed")
    write File.join(dir, "skills", "inner", "SKILL.md"), skill_md(name: "inner")
    write File.join(dir, "SKILL.md"), skill_md(name: "mixed")
    components = Handlr::Store.scan_components(dir)
    assert_equal ["inner"], components["skills"].keys
  end

  def test_scan_metadata_from_plugin_json
    dir = home("fixture", "meta")
    write File.join(dir, ".claude-plugin", "plugin.json"),
          '{"name":"Pretty Name","description":"Desc here"}'
    write File.join(dir, "skills", "s", "SKILL.md"), skill_md

    scan = Handlr::Store.scan(dir)
    assert_equal "Pretty Name", scan["displayName"]
    assert_equal "Desc here", scan["description"]
  end

  def test_scan_description_falls_back_to_first_skill
    dir = home("fixture", "fallback")
    write File.join(dir, "skills", "s", "SKILL.md"), skill_md(description: "From skill")

    scan = Handlr::Store.scan(dir)
    assert_equal "fallback", scan["displayName"]
    assert_equal "From skill", scan["description"]
  end

  def test_marketplace_catalog_path
    dir = home("fixture", "cat")
    assert_nil Handlr::Store.marketplace_catalog_path(dir)
    write File.join(dir, ".claude-plugin", "marketplace.json"), "{}"
    assert_equal File.join(dir, ".claude-plugin", "marketplace.json"),
                 Handlr::Store.marketplace_catalog_path(dir)
  end
end
