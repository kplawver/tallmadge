# frozen_string_literal: true

module Tallmadge
  # Composes the managed ~/.agents/agents.md and mcp.json files from user
  # fragments + active plugin components. Adoption moves an existing
  # unmanaged file aside as the user's baseline before the first compose.
  # Extracted from Activator to keep link management and file composition
  # concerns separate.
  class Composer
    AGENTS_MD_MARKER = "<!-- managed by tallmadge -->"

    attr_reader :state

    def initialize(state)
      @state = state
    end

    def compose_agents_md!
      target = File.join(Paths.agents_home, "agents.md")
      user_fragment = read_user_content("agentsMd")
      fragments = active_agents_md_fragments

      if user_fragment.nil? && fragments.empty?
        if @state.composed["agentsMd"] && File.exist?(target) && agents_md_managed?(target)
          File.delete(target)
          Reporter.info "removed composed agents.md (no active content left)"
        end
        @state.composed["agentsMd"] = false
        return
      end

      adopt_agents_md!(target) if File.exist?(target) && !agents_md_managed?(target)
      # Adoption may have added a user fragment.
      user_fragment ||= read_user_content("agentsMd")

      lines = [AGENTS_MD_MARKER, ""]
      if user_fragment && !user_fragment.strip.empty?
        lines << user_fragment.strip << ""
      end
      fragments.each do |plugin_id, content|
        lines << "<!-- tallmadge:begin #{plugin_id} -->"
        lines << content.strip
        lines << "<!-- tallmadge:end #{plugin_id} -->"
        lines << ""
      end

      write_atomic(target, lines.join("\n").rstrip + "\n")
      @state.composed["agentsMd"] = true
      Reporter.ok "composed #{target} (#{fragments.size} plugin fragment#{fragments.size == 1 ? '' : 's'})"
    end

    def compose_mcp_json!
      target = File.join(Paths.agents_home, "mcp.json")
      adopt_mcp_json!(target) if File.exist?(target) && !@state.composed["mcpJson"]

      servers = {}
      origins = {}

      user_servers.each do |name, config|
        servers[name] = config
        origins[name] = "user"
      end

      @state.profile_plugins.each do |id, entry|
        info = (entry["components"] || {})["mcpServers"]
        next if info.nil? || info.empty?

        plugin_servers = plugin_mcp_servers(id)
        info.each_key do |server_name|
          next unless info[server_name]["active"]

          config = plugin_servers[server_name]
          next unless config

          if servers.key?(server_name)
            Reporter.warn "mcp server '#{server_name}' already provided by " \
                          "#{origins[server_name]}, keeping first"
            next
          end
          servers[server_name] = config
          origins[server_name] = id
        end
      end

      if servers.empty?
        if @state.composed["mcpJson"] && File.exist?(target)
          File.delete(target)
          Reporter.info "removed composed mcp.json (no active servers left)"
        end
        @state.composed["mcpJson"] = false
        @state.mcp_origins.clear
        return
      end

      write_atomic(target, JSON.pretty_generate({ "mcpServers" => servers }) + "\n")
      @state.composed["mcpJson"] = true
      @state.set_mcp_origins(origins)
      Reporter.ok "composed #{target} (#{servers.size} server#{servers.size == 1 ? '' : 's'})"
    end

    def remove_composed_files!
      agents_md_target = File.join(Paths.agents_home, "agents.md")
      if @state.composed["agentsMd"] && File.exist?(agents_md_target) && agents_md_managed?(agents_md_target)
        File.delete(agents_md_target)
      end
      @state.composed["agentsMd"] = false

      mcp_target = File.join(Paths.agents_home, "mcp.json")
      if @state.composed["mcpJson"] && File.exist?(mcp_target)
        File.delete(mcp_target)
      end
      @state.composed["mcpJson"] = false
      @state.mcp_origins.clear
    end

    def agents_md_managed?(target)
      File.open(target, &:readline).strip == AGENTS_MD_MARKER
    rescue EOFError
      false
    end

    private

    def adopt_agents_md!(target)
      adopt_composed_file!(target, "agentsMd", "agents.md", "user fragment")
    end

    def adopt_mcp_json!(target)
      adopt_composed_file!(target, "mcpJson", "mcp.json", "user copy")
    end

    def adopt_composed_file!(target, key, filename, kind)
      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      backup = File.join(Paths.backups_dir, "#{stamp}-#{key}-#{filename}")
      profile_dir = Paths.profile_dir(@state.active_profile_name)
      user_copy = File.join(profile_dir, filename)
      FileUtils.mkdir_p(Paths.backups_dir)
      FileUtils.mkdir_p(profile_dir)
      FileUtils.cp(target, user_copy)
      FileUtils.mv(target, backup)
      @state.user_content[key] = "profiles/#{@state.active_profile_name}/#{filename}"
      Reporter.warn "adopted existing #{target} (backup: #{backup}, #{kind}: #{user_copy})"
    end

    def read_user_content(key)
      rel = @state.user_content[key]
      return nil unless rel

      path = File.join(Paths.tallmadge_home, rel)
      File.exist?(path) ? File.read(path) : nil
    end

    def user_servers
      rel = @state.user_content["mcpJson"]
      return {} unless rel

      path = File.join(Paths.tallmadge_home, rel)
      return {} unless File.exist?(path)

      data = JSON.parse(File.read(path)) rescue {}
      servers = data["mcpServers"]
      servers.is_a?(Hash) ? servers : {}
    end

    def active_agents_md_fragments
      fragments = []
      @state.profile_plugins.each do |id, entry|
        info = (entry["components"] || {})["agentsMd"]
        next unless info && info["active"]

        path = plugin_agents_md_path(id)
        next unless path

        fragments << [id, File.read(path)]
      end
      fragments
    end

    def plugin_agents_md_path(id)
      dir = Paths.plugin_dir(id)
      entry = Dir.children(dir).find do |f|
        f.casecmp?("agents.md") && File.file?(File.join(dir, f))
      end
      entry && File.join(dir, entry)
    end

    def plugin_mcp_servers(id)
      dir = Paths.plugin_dir(id)
      file = %w[mcp.json .mcp.json].map { |f| File.join(dir, f) }
                                    .find { |f| File.file?(f) }
      return {} unless file

      data = JSON.parse(File.read(file)) rescue {}
      servers = data["mcpServers"]
      servers.is_a?(Hash) ? servers : {}
    end

    def write_atomic(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}"
      File.write(tmp, content)
      File.rename(tmp, path)
    end
  end
end
