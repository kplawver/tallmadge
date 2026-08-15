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

module Tallmadge
  VERSION = "0.1.0"

  # Every user-facing failure raises this; the CLI rescues it, prints via
  # Reporter, and exits 1.
  class Error < StandardError; end

  # Usage errors (bad arguments, unknown ids); Thor renders them itself.
  class UsageError < Thor::Error; end
end

require_relative "tallmadge/paths"
require_relative "tallmadge/reporter"
require_relative "tallmadge/state"
require_relative "tallmadge/git"
require_relative "tallmadge/frontmatter"
require_relative "tallmadge/store"
require_relative "tallmadge/activator"
require_relative "tallmadge/harness"
require_relative "tallmadge/http"
require_relative "tallmadge/marketplace"
require_relative "tallmadge/hub"
require_relative "tallmadge/skills"
require_relative "tallmadge/updater"
require_relative "tallmadge/commands/install"
require_relative "tallmadge/cli"
