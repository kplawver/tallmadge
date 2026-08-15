# frozen_string_literal: true

require "thor"
require "rainbow"
require "json"
require "fileutils"
require "tmpdir"
require "open3"
require "net/http"
require "uri"
require "time"
require "set"

module Handlr
  VERSION = "0.1.0"

  # Every user-facing failure raises this; the CLI rescues it, prints via
  # Reporter, and exits 1.
  class Error < StandardError; end

  # Usage errors (bad arguments, unknown ids); Thor renders them itself.
  class UsageError < Thor::Error; end
end

require_relative "handlr/paths"
require_relative "handlr/reporter"
require_relative "handlr/state"
require_relative "handlr/git"
require_relative "handlr/frontmatter"
require_relative "handlr/store"
require_relative "handlr/activator"
require_relative "handlr/harness"
require_relative "handlr/http"
require_relative "handlr/marketplace"
require_relative "handlr/hub"
require_relative "handlr/skills"
require_relative "handlr/updater"
require_relative "handlr/commands/install"
require_relative "handlr/cli"
