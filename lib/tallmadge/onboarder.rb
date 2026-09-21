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

    # Incremental version of `run`: picks up new external MCP configs,
    # marketplaces, and plugins without the destructive backup/migration
    # of ~/.agents. Also detects and links newly installed harnesses.
    def refresh(non_interactive: false, auto_yes: false)
      Reporter.info "=== Tallmadge Refresh ==="

      Paths.ensure_skeleton!

      mcp_findings = inspect_mcp_configs
      marketplace_findings = inspect_harness_marketplaces
      plugin_findings = inspect_harness_plugins

      if mcp_findings.any?
        handle_mcp_imports(mcp_findings, non_interactive: non_interactive, auto_yes: auto_yes)
      end

      if marketplace_findings.any?
        handle_marketplace_imports(marketplace_findings, non_interactive: non_interactive, auto_yes: auto_yes)
      end

      if plugin_findings.any?
        handle_plugin_imports(plugin_findings, non_interactive: non_interactive, auto_yes: auto_yes)
      end

      detect_and_link_new_harnesses(non_interactive: non_interactive, auto_yes: auto_yes)

      if @state.plugins.any? || @state.user_content["agentsMd"] || @state.user_content["mcpJson"]
        Activator.new(@state).apply_profile!
      end

      @state.save
      Reporter.ok "Refresh complete!"
    end

    # Links harnesses installed since last setup/refresh and warns about
    # previously linked harnesses that are no longer installed. Linking
    # writes symlinks into each harness's own config directory, so ask
    # first unless the caller already accepted every prompt.
    def detect_and_link_new_harnesses(non_interactive: false, auto_yes: false)
      installed = Harness.installed_harnesses
      linked = @state.harnesses.keys
      fresh = installed - linked

      if fresh.any?
        Reporter.info "\nNewly detected harnesses: #{fresh.join(', ')}"
        prompt = "Bridge their gaps with symlinks into their config directories?"
        if auto_yes || (non_interactive ? true : prompt_yes_no(prompt, default: true))
          fresh.each do |hid|
            Harness.link(@state, hid)
          rescue Error => e
            Reporter.err "Failed to link harness '#{hid}': #{e.message}"
          end
        else
          Reporter.info "Skipped; run `clpr link HARNESS` to bridge them later."
        end
      end

      (linked - installed).each do |hid|
        Reporter.warn "harness '#{hid}' is no longer installed; links will be skipped"
      end
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
