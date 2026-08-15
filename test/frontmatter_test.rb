# frozen_string_literal: true

require_relative "test_helper"

class FrontmatterTest < Minitest::Test
  def test_parse_simple_values
    meta, body = Handlr::Frontmatter.parse("---\nname: hello\ndescription: Says hi\n---\nBody text\n")
    assert_equal "hello", meta["name"]
    assert_equal "Says hi", meta["description"]
    assert_equal "Body text\n", body
  end

  def test_parse_quoted_values
    meta, = Handlr::Frontmatter.parse("---\nname: \"hello\"\ndescription: 'quoted'\n---\nx\n")
    assert_equal "hello", meta["name"]
    assert_equal "quoted", meta["description"]
  end

  def test_parse_csv_values_for_list_keys
    meta, = Handlr::Frontmatter.parse("---\ntags: one, two, three\n---\nx\n")
    assert_equal %w[one two three], meta["tags"]
  end

  def test_parse_json_array_value
    meta, = Handlr::Frontmatter.parse("---\ntags: [\"a\", \"b\"]\n---\nx\n")
    assert_equal %w[a b], meta["tags"]
  end

  def test_non_list_key_stays_raw_string
    meta, = Handlr::Frontmatter.parse("---\ndescription: a, b, c\n---\nx\n")
    assert_equal "a, b, c", meta["description"]
  end

  def test_no_frontmatter
    meta, body = Handlr::Frontmatter.parse("just text")
    assert_equal({}, meta)
    assert_equal "just text", body
  end

  def test_serialize_sorts_keys_alphabetically
    text = Handlr::Frontmatter.serialize({ "name" => "x", "description" => "y" }, "body")
    assert_equal "---\ndescription: y\nname: x\n---\n\nbody", text
  end

  def test_serialize_joins_arrays
    text = Handlr::Frontmatter.serialize({ "tags" => %w[a b] }, "")
    assert_includes text, "tags: a, b"
  end

  def test_yaml_fallback_parses_real_yaml_skill_md
    sample = <<~MD
      ---
      name: real-world
      description: full YAML skill
      metadata:
        author: someone
      ---
      Body here
    MD
    meta, body = Handlr::Frontmatter.parse(sample)
    assert_equal "real-world", meta["name"]
    assert_equal({ "author" => "someone" }, meta["metadata"])
    assert_equal "Body here\n", body
  end

  def test_roundtrip
    text = Handlr::Frontmatter.serialize({ "kind" => "task", "enabled" => true }, "prompt")
    meta, body = Handlr::Frontmatter.parse(text)
    assert_equal "task", meta["kind"]
    assert_equal "prompt", body
  end
end
