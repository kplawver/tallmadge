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
        next if @state.mcp_disabled.include?(name)

        servers[name] = config
        origins[name] = "user"
      end

      @state.profile_plugins.each do |id, entry|
        info = (entry["components"] || {})["mcpServers"]
        next if info.nil? || info.empty?

        plugin_servers = Store.mcp_servers(id)
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

    # Composes ~/.agents/hooks.json (Claude-shaped: {"hooks": {event => groups}})
    # from active plugin hooks. An existing unmanaged file is left alone.
    def compose_hooks_json!
      target = File.join(Paths.agents_home, "hooks.json")
      events = active_hook_events

      if events.empty?
        if @state.composed["hooksJson"] && File.exist?(target)
          File.delete(target)
          Reporter.info "removed composed hooks.json (no active hooks left)"
        end
        @state.composed["hooksJson"] = false
        return
      end

      if File.exist?(target) && !@state.composed["hooksJson"]
        Reporter.warn "#{target} exists and is not managed by tallmadge; active hooks not composed"
        return
      end

      write_atomic(target, JSON.pretty_generate({ "hooks" => events }) + "\n")
      @state.composed["hooksJson"] = true
      count = events.values.sum { |groups| groups.sum { |g| g["hooks"].size } }
      Reporter.ok "composed #{target} (#{count} hook#{count == 1 ? '' : 's'})"
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

      hooks_target = File.join(Paths.agents_home, "hooks.json")
      File.delete(hooks_target) if @state.composed["hooksJson"] && File.exist?(hooks_target)
      @state.composed["hooksJson"] = false
    end

    def agents_md_managed?(target)
      File.open(target, &:readline).strip == AGENTS_MD_MARKER
    rescue EOFError
      false
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

    private

    PLUGIN_ROOT_VAR = "${CLAUDE_PLUGIN_ROOT}"

    # {event => [{"matcher", "hooks" => [handler]}]} for every active hook,
    # with the plugin-root variable resolved to the plugin's store dir.
    def active_hook_events
      events = Hash.new { |h, event| h[event] = [] }
      @state.profile_plugins.each do |id, entry|
        active = ((entry["components"] || {})["hooks"] || {}).select { |_, info| info["active"] }
        next if active.empty?

        plugin_hooks = Store.hooks(id)
        active.each_key do |hook_id|
          hook = plugin_hooks[hook_id] or next
          group = events[hook["event"]].find { |g| g["matcher"] == hook["matcher"] }
          unless group
            group = { "matcher" => hook["matcher"], "hooks" => [] }.compact
            events[hook["event"]] << group
          end
          group["hooks"] << resolve_plugin_root(hook["handler"], Paths.plugin_dir(id))
        end
      end
      events
    end

    def resolve_plugin_root(value, plugin_dir)
      case value
      when String then value.gsub(PLUGIN_ROOT_VAR, plugin_dir)
      when Hash then value.transform_values { |v| resolve_plugin_root(v, plugin_dir) }
      when Array then value.map { |v| resolve_plugin_root(v, plugin_dir) }
      else value
      end
    end

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

    def write_atomic(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp.#{Process.pid}"
      File.write(tmp, content)
      File.rename(tmp, path)
    end
  end
end
