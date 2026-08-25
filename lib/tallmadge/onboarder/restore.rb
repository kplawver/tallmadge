# frozen_string_literal: true

require "fileutils"

module Tallmadge
  class Onboarder
    # Reverts Tallmadge management: tears down active profile symlinks and
    # bridge links, restores the most recent (or specified) ~/.agents backup,
    # and clears managed state for user content and composed files.
    module Restore
      def restore(backup_path: nil, non_interactive: false, auto_yes: false)
        Reporter.info "=== Tallmadge Management Removal & Restore ==="

        backups = Dir.glob(File.join(Paths.backups_dir, "*-agents-backup")).sort
        target_backup = backup_path || backups.last

        if target_backup.nil? || !Dir.exist?(target_backup)
          raise Error, "No ~/.agents backup found in #{Paths.backups_dir} to restore from."
        end

        Reporter.info "Target backup to restore: #{target_backup}"
        prompt = "This will remove all Tallmadge symlinks, unmanage ~/.agents, and restore #{target_backup}. Proceed?"
        should_proceed = auto_yes || (non_interactive ? true : prompt_yes_no(prompt, default: true))
        return unless should_proceed

        # 1. Teardown active profile symlinks and bridge links
        Activator.new(@state).teardown_profile!

        # 2. Clear current ~/.agents directory
        FileUtils.rm_rf(Paths.agents_home)

        # 3. Restore backup to ~/.agents
        FileUtils.cp_r(target_backup, Paths.agents_home)
        Reporter.ok "Restored ~/.agents from #{target_backup}"

        # 4. Remove managed state for userContent and composed files
        @state.user_content["agentsMd"] = nil
        @state.user_content["mcpJson"] = nil
        @state.composed["agentsMd"] = false
        @state.composed["mcpJson"] = false
        @state.mcp_origins.clear
        @state.save

        Reporter.ok "Tallmadge management removed and ~/.agents restored successfully."
      end
    end
  end
end
