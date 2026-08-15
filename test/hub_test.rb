# frozen_string_literal: true

require_relative "test_helper"

class HubTest < Minitest::Test
  include HandlrTestHelpers

  BUNDLE = {
    "manifest" => {
      "version" => 1,
      "name" => "Test Bundle",
      "description" => "Bundle desc",
      "publicMetadata" => { "summary" => "Sum" }
    },
    "agentProfiles" => [
      { "id" => "helper", "name" => "helper", "displayName" => "The Helper",
        "description" => "Helps", "enabled" => true, "role" => "assistant",
        "systemPrompt" => "You help.", "guidelines" => "Be nice.",
        "connection" => { "type" => "api" } }
    ],
    "skills" => [
      { "id" => "sk1", "name" => "Skill One", "description" => "First skill",
        "instructions" => "Do the thing." }
    ],
    "repeatTasks" => [
      { "id" => "morning", "name" => "Morning", "prompt" => "Brief me.",
        "intervalMinutes" => 1440, "enabled" => true, "runOnStartup" => false }
    ],
    "memories" => [],
    "mcpServers" => []
  }.freeze

  def test_write_bundle_tree_generates_protocol_files
    dir = store("test-bundle")
    FileUtils.mkdir_p(dir)
    Handlr::Hub.write_bundle_tree(BUNDLE, dir)

    agent = File.read(File.join(dir, "agents", "helper", "agent.md"))
    assert_match(/name: The Helper/, agent)
    assert_match(/description: Helps/, agent)
    assert_match(/role: assistant/, agent)
    assert_match(/connection-type: api/, agent)
    assert_match(/You help\./, agent)
    assert_match(/## Guidelines/, agent)
    assert_match(/Be nice\./, agent)

    skill = File.read(File.join(dir, "skills", "sk1", "SKILL.md"))
    assert_match(/name: Skill One/, skill)
    assert_match(/description: First skill/, skill)
    assert_match(/Do the thing\./, skill)

    task = File.read(File.join(dir, "tasks", "morning", "task.md"))
    assert_match(/kind: task/, task)
    assert_match(/intervalMinutes: 1440/, task)
    assert_match(/enabled: true/, task)
    assert_match(/Brief me\./, task)

    refute File.exist?(File.join(dir, "mcp.json")) # empty mcpServers skipped

    plugin_json = JSON.parse(File.read(File.join(dir, ".claude-plugin", "plugin.json")))
    assert_equal "Test Bundle", plugin_json["name"]
    assert_equal "Bundle desc", plugin_json["description"]
  end

  def test_mcp_servers_array_shape_normalized
    servers = Handlr::Hub.normalize_mcp_servers([
      { "name" => "github", "command" => "npx", "args" => ["-y", "x"] },
      { "id" => "fs", "command" => "fs-mcp" }
    ])
    assert_equal "npx", servers["github"]["command"]
    refute servers["github"].key?("name")
    assert_equal "fs-mcp", servers["fs"]["command"]
    refute servers["fs"].key?("id")
  end

  def test_mcp_servers_map_shape_passthrough
    servers = Handlr::Hub.normalize_mcp_servers({ "a" => { "command" => "x" } })
    assert_equal({ "a" => { "command" => "x" } }, servers)
  end

  def test_mcp_written_to_plugin_tree
    bundle = BUNDLE.merge("mcpServers" => [
      { "name" => "github", "command" => "npx", "args" => ["-y", "srv"] }
    ])
    dir = store("mcpbundle")
    Handlr::Hub.write_bundle_tree(bundle, dir)
    mcp = JSON.parse(File.read(File.join(dir, "mcp.json")))
    assert_equal "npx", mcp.dig("mcpServers", "github", "command")
  end

  def test_skill_instructions_with_existing_frontmatter_kept_verbatim
    bundle = BUNDLE.merge("skills" => [
      { "id" => "raw", "instructions" => "---\nname: raw\n---\nRaw body" }
    ])
    dir = store("rawbundle")
    Handlr::Hub.write_bundle_tree(bundle, dir)
    content = File.read(File.join(dir, "skills", "raw", "SKILL.md"))
    assert content.start_with?("---\nname: raw\n---")
    assert_includes content, "Raw body"
  end

  def test_memories_object_and_string_shapes
    bundle = BUNDLE.merge("memories" => [
      { "id" => "pref", "title" => "Prefs", "content" => "Remember this.",
        "tags" => %w[a b] },
      "plain string memory"
    ])
    dir = store("membundle")
    Handlr::Hub.write_bundle_tree(bundle, dir)

    pref = File.read(File.join(dir, "memories", "pref.md"))
    assert_match(/title: Prefs/, pref)
    assert_match(/importance: medium/, pref)
    assert_match(/tags: a, b/, pref)
    assert_match(/Remember this\./, pref)

    plain = File.read(File.join(dir, "memories", "memory-2.md"))
    assert_match(/plain string memory/, plain)
    assert_match(/importance: medium/, plain)
  end

  def test_generated_tree_is_scannable
    dir = store("scanbundle")
    Handlr::Hub.write_bundle_tree(BUNDLE, dir)
    components = Handlr::Store.scan_components(dir)
    assert_equal ["sk1"], components["skills"].keys
    assert_equal ["helper"], components["agents"].keys
    assert_equal ["morning"], components["tasks"].keys
  end
end
