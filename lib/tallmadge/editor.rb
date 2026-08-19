# frozen_string_literal: true

module Tallmadge
  # Opens user-content files (agents.md, mcp.json) in whatever application
  # the OS associates with them. Missing files are created and registered
  # first, so `clpr edit agents.md` doubles as "add a new file to the store".
  module Editor
    # CLI filename -> state userContent key.
    FILES = {
      "agents.md" => "agentsMd",
      "mcp.json" => "mcpJson"
    }.freeze

    module_function

    def edit(state, name)
      filename = FILES.keys.find { |f| f.casecmp?(name.to_s) }
      raise Error, "cannot edit '#{name}' (editable files: #{FILES.keys.join(', ')})" unless filename

      path = ensure_user_file!(state, FILES[filename], filename)
      open_with_default_app(path)
      Reporter.ok "opened #{path}"
      Reporter.info Reporter.dim("changes appear in #{File.join(Paths.agents_home, filename)} " \
                                 "after the next rebuild (activate, deactivate, or profile switch)")
    end

    # Returns the absolute path to the user's copy, creating it when absent.
    # An existing state entry wins even when its file was deleted, so
    # legacy locations (e.g. store/user/agents.md) keep working; new files
    # follow the adoption convention profiles/<active>/<filename>.
    def ensure_user_file!(state, key, filename)
      rel = state.user_content[key]
      return relink_legacy(state, key, rel, filename) if rel

      create_user_file(state, key, filename)
    end

    def relink_legacy(state, key, rel, filename)
      path = File.join(Paths.tallmadge_home, rel)
      return path if File.exist?(path)

      write_seed(path, filename)
      Reporter.warn "recreated missing #{path}"
      path
    end

    def create_user_file(state, key, filename)
      path = File.join(Paths.profile_dir(state.active_profile_name), filename)
      write_seed(path, filename)
      state.user_content[key] = "profiles/#{state.active_profile_name}/#{filename}"
      state.save
      Reporter.ok "created #{path}"
      path
    end

    # mcp.json seeds valid JSON so the file parses before the user touches it.
    def write_seed(path, filename)
      FileUtils.mkdir_p(File.dirname(path))
      content = filename == "mcp.json" ? "#{JSON.pretty_generate("mcpServers" => {})}\n" : ""
      File.write(path, content)
    end

    def open_with_default_app(path)
      cmd = opener(path)
      ok = system(*cmd) rescue nil
      raise Error, "'#{cmd.first}' could not open #{path} — open the file manually" unless ok
    end
    # Platform launcher: macOS `open`, Windows `start`, elsewhere `xdg-open`.
    def opener(path)
      case RbConfig::CONFIG["host_os"]
      when /darwin/ then ["open", path]
      when /mswin|mingw|cygwin/ then ["cmd", "/c", "start", "", path] # "" is the window title arg
      else ["xdg-open", path]
      end
    end
  end
end
