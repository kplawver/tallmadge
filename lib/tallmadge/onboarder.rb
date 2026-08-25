# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

require_relative "onboarder/scanner"
require_relative "onboarder/migration"
require_relative "onboarder/restore"

module Tallmadge
  # First-time setup and onboarding orchestrator. Coordinates detection
  # (Scanner), import/migration (Migration), and restore (Restore) of
  # ~/.agents and external harness configurations.
  class Onboarder
    include Scanner
    include Migration
    include Restore

    attr_reader :state, :input, :output

    def initialize(state, input: $stdin, output: $stdout)
      @state = state
      @input = input
      @output = output
    end

    def run(non_interactive: false, auto_yes: false)
      Reporter.info "=== Tallmadge Setup & Onboarding ==="

      agents_findings = inspect_agents_dir
      mcp_findings = inspect_mcp_configs
      marketplace_findings = inspect_harness_marketplaces
      plugin_findings = inspect_harness_plugins

      if !agents_findings[:exists] && mcp_findings.empty? &&
         marketplace_findings.empty? && plugin_findings.empty?
        Reporter.info "No existing unmanaged .agents directory or external configurations detected."
        created = Paths.ensure_skeleton!
        created.each { |dir| Reporter.ok "created #{dir}" }
        Reporter.ok "Tallmadge initialized successfully."
        return
      end

      if agents_findings[:exists]
        if agents_findings[:managed]
          Reporter.ok "~/.agents is already managed by Tallmadge."
        else
          handle_agents_migration(agents_findings, non_interactive: non_interactive, auto_yes: auto_yes)
        end
      else
        Paths.ensure_skeleton!
      end

      if mcp_findings.any?
        handle_mcp_imports(mcp_findings, non_interactive: non_interactive, auto_yes: auto_yes)
      end

      if marketplace_findings.any?
        handle_marketplace_imports(marketplace_findings, non_interactive: non_interactive, auto_yes: auto_yes)
      end

      if plugin_findings.any?
        handle_plugin_imports(plugin_findings, non_interactive: non_interactive, auto_yes: auto_yes)
      end

      finalize_setup
      Reporter.ok "Setup and onboarding complete!"
    end

    # Shared by Migration and Restore for interactive confirmation.
    def prompt_yes_no(prompt, default: true)
      default_str = default ? "[Y/n]" : "[y/N]"
      @output.print "#{prompt} #{default_str} "
      answer = @input.gets&.strip&.downcase
      return default if answer.nil? || answer.empty?

      answer.start_with?("y")
    end
  end
end
