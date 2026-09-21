# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "fileutils"
require "tmpdir"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "tallmadge"

# Every test runs in a throwaway HOME so the real ~/.agents, ~/.tallmadge,
# ~/.omp, and ~/.pi are never touched. Harness relocation env vars are
# cleared too: CI runners set XDG_CONFIG_HOME, which would otherwise
# point kilo/amp/devin paths outside the sandbox. Tests that exercise
# relocation set the var explicitly (see with_env in harness_test).
RELOCATION_ENV_VARS = %w[
  XDG_CONFIG_HOME CODEX_HOME CLINE_DIR CLAUDE_CONFIG_DIR CURSOR_CONFIG_DIR COPILOT_HOME
].freeze

module TallmadgeTestHelpers
  def setup
    super
    @original_home = ENV["HOME"]
    @original_relocation_env = RELOCATION_ENV_VARS.to_h { |key| [key, ENV[key]] }
    RELOCATION_ENV_VARS.each { |key| ENV.delete(key) }
    @sandbox = Dir.mktmpdir("tallmadge-test")
    ENV["HOME"] = @sandbox
    Rainbow.enabled = false
    Tallmadge::Paths.ensure_skeleton!
  end

  def teardown
    ENV["HOME"] = @original_home
    @original_relocation_env.each { |key, value| ENV[key] = value }
    FileUtils.rm_rf(@sandbox)
    super
  end

  # Fresh load from disk; call again after any operation that saves.
  def state
    Tallmadge::State.load
  end

  def home(*parts)
    File.join(@sandbox, *parts)
  end

  def agents(*parts)
    home(".agents", *parts)
  end

  def store(*parts)
    home(".tallmadge", "store", *parts)
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def skill_md(name: "test-skill", description: "A test skill", body: "Body")
    "---\nname: #{name}\ndescription: #{description}\n---\n\n#{body}\n"
  end
end
