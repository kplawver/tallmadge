# frozen_string_literal: true

module Tallmadge
  # MCP server management across the user copy and installed plugins for
  # the `clpr mcp` commands. Name resolution is always user config first,
  # then plugin-provided.
  module Mcp
    NAME_RE = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/
    MAX_NAME_LENGTH = 64

    module_function

    # plugin ids whose installed components include an mcp server with
    # this name.
    def plugin_owners(state, name)
      state.plugins.filter_map { |id, e| e.dig("components", "mcpServers", name) ? id : nil }
    end

    def type_of(config)
      return "unknown" unless config.is_a?(Hash)
      return config["type"] || "http" if config["url"]
      return "stdio" if config["command"]

      config["type"] || "other"
    end

    def list(state)
      rows = []
      disabled = state.mcp_disabled
      Composer.new(state).user_servers.each do |name, config|
        rows << [name, "user", type_of(config), !disabled.include?(name)]
      end

      servers_by_plugin = Hash.new { |h, id| h[id] = Store.mcp_servers(id) }
      state.plugins.each do |id, entry|
        names = (entry.dig("components", "mcpServers") || {}).keys
        next if names.empty?

        names.each do |name|
          active = state.profile_plugins.dig(id, "components", "mcpServers", name, "active") ? true : false
          rows << [name, id, type_of(servers_by_plugin[id][name]), active]
        end
      end

      if rows.empty?
        Reporter.info "no mcp servers configured"
        return
      end

      rows.sort_by!(&:first)
      table = rows.map do |name, origin, type, active|
        status = active ? Rainbow("active").green.to_s : Rainbow("inactive").faint.to_s
        [name, origin, type, status]
      end
      Reporter.table(table, %w[server origin type active])
    end

    def get(state, name)
      origin, config, = find_server(state, name)
      puts "name: #{name}"
      puts "origin: #{origin}"
      puts "active: #{server_active?(state, name, origin)}"
      puts JSON.pretty_generate(config)
    end

    def add(state, name, command, url: nil, transport: nil, env: nil, config: nil)
      validate_name!(name)
      config = build_config(command, url, transport, env_hash(env), config)

      Paths.ensure_skeleton!
      composer = Composer.new(state)
      adopt_before_write(composer, state)

      if composer.user_servers.key?(name)
        raise Error, "mcp server '#{name}' already exists in your user config " \
                     "(remove it first: clpr mcp remove #{name})"
      end
      owners = plugin_owners(state, name)
      unless owners.empty?
        raise Error, "mcp server '#{name}' is already provided by plugin #{owners.join(', ')}"
      end

      path = Editor.ensure_user_file!(state, "mcpJson", "mcp.json")
      data = read_user_mcp_json(path)
      data["mcpServers"] ||= {}
      data["mcpServers"][name] = config
      File.write(path, JSON.pretty_generate(data) + "\n")

      composer.compose_mcp_json!
      state.save
      Harness.maintain!(state)
      Reporter.ok "added mcp server #{name}"
    end

    def remove(state, name)
      composer = Composer.new(state)
      if composer.user_servers.key?(name)
        path = File.join(Paths.tallmadge_home, state.user_content["mcpJson"])
        data = read_user_mcp_json(path)
        data["mcpServers"].delete(name)
        File.write(path, JSON.pretty_generate(data) + "\n")
        state.enable_mcp_server!(name)
        composer.compose_mcp_json!
        state.save
        Harness.maintain!(state)
        Reporter.ok "removed mcp server #{name}"
        return
      end

      owners = plugin_owners(state, name)
      raise_unknown!(state, name) if owners.empty?

      raise Error, "mcp server '#{name}' is provided by plugin #{owners.join(', ')} " \
                   "— deactivate it instead (clpr mcp deactivate #{name})"
    end

    def activate(state, name)
      composer = Composer.new(state)
      if composer.user_servers.key?(name)
        unless state.mcp_disabled.include?(name)
          Reporter.warn "mcp server '#{name}' is already active"
          return
        end

        state.enable_mcp_server!(name)
        composer.compose_mcp_json!
        state.save
        Harness.maintain!(state)
        Reporter.ok "activated mcp server #{name}"
        return
      end

      owners = plugin_owners(state, name)
      raise_unknown!(state, name) if owners.empty?
      if owners.size > 1
        raise Error, "mcp server '#{name}' exists in multiple plugins: #{owners.join(', ')} " \
                     "— activate via clpr activate <plugin> --mcp #{name}"
      end

      Activator.new(state).activate(owners.first, only: [["mcpServers", name]])
    end

    def deactivate(state, name)
      composer = Composer.new(state)
      if composer.user_servers.key?(name)
        if state.mcp_disabled.include?(name)
          Reporter.warn "mcp server '#{name}' is already inactive"
          return
        end

        state.disable_mcp_server!(name)
        composer.compose_mcp_json!
        state.save
        Harness.maintain!(state)
        Reporter.ok "deactivated mcp server #{name}"
        return
      end

      owners = plugin_owners(state, name)
      raise_unknown!(state, name) if owners.empty?
      if owners.size > 1
        raise Error, "mcp server '#{name}' exists in multiple plugins: #{owners.join(', ')} " \
                     "— deactivate via clpr deactivate <plugin> --mcp #{name}"
      end

      Activator.new(state).deactivate(owners.first, only: [["mcpServers", name]])
    end

    # ---- shared helpers -----------------------------------------------------

    # [origin, config] for name; user config wins over plugin copies.
    def find_server(state, name)
      user = Composer.new(state).user_servers
      return ["user", user[name]] if user.key?(name)

      owners = plugin_owners(state, name)
      raise_unknown!(state, name) if owners.empty?

      [owners.first, Store.mcp_servers(owners.first)[name]]
    end

    def server_active?(state, name, origin)
      if origin == "user"
        !state.mcp_disabled.include?(name)
      else
        state.profile_plugins.dig(origin, "components", "mcpServers", name, "active") ? true : false
      end
    end

    def raise_unknown!(state, name)
      user = Composer.new(state).user_servers.keys
      plugins = state.plugins.flat_map do |id, entry|
        (entry.dig("components", "mcpServers") || {}).keys.map { |n| "#{n} (#{id})" }
      end
      msg = "no mcp server named '#{name}'"
      msg += " — available: #{(user + plugins).join(', ')}" unless user.empty? && plugins.empty?
      raise Error, msg
    end

    def validate_name!(name)
      return if name.length <= MAX_NAME_LENGTH && name.match?(NAME_RE)

      raise Error, "invalid mcp server name '#{name}' " \
                   "(allowed: letters, digits, '-', '_'; max #{MAX_NAME_LENGTH} chars)"
    end

    # Exactly one input mode: raw --config JSON, --url, or a stdio command.
    def build_config(command, url, transport, env, config)
      if config
        raise Error, "--config cannot be combined with --url, --env, or a command" if url || env || command.any?

        return parse_config(config)
      end

      if url
        raise Error, "--url cannot be combined with a command or --env" if command.any? || env

        transport ||= "http"
        raise Error, "--transport must be http or sse" unless %w[http sse].include?(transport)

        return { "type" => transport, "url" => url }
      end

      if command.empty?
        raise Error, "pass a command (clpr mcp add NAME -- CMD ARGS...), --url URL, or --config JSON"
      end

      cfg = { "command" => command[0], "args" => command[1..] }
      cfg["env"] = env if env && !env.empty?
      cfg
    end

    def parse_config(raw)
      data = JSON.parse(raw)
      raise Error, "--config must be a JSON object" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError => e
      raise Error, "invalid --config JSON: #{e.message}"
    end

    def env_hash(env)
      return nil if env.nil? || env.empty?
      return env if env.is_a?(Hash)

      env.to_h { |pair| split_env_pair(pair) }
    end

    def split_env_pair(pair)
      key, sep, value = pair.to_s.partition("=")
      raise Error, "invalid --env value '#{pair}' (expected KEY=VALUE)" if sep.empty? || key.empty?

      [key, value]
    end

    # An unmanaged composed mcp.json must be adopted as the user copy
    # before we seed a fresh one, or its servers would be orphaned.
    def adopt_before_write(composer, state)
      unregistered = state.user_content["mcpJson"].nil?
      return unless unregistered && !state.composed["mcpJson"]
      return unless File.exist?(File.join(Paths.agents_home, "mcp.json"))

      composer.compose_mcp_json!
    end

    def read_user_mcp_json(path)
      data = JSON.parse(File.read(path))
      raise Error, "cannot parse user mcp.json (#{path}): expected a JSON object" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError => e
      raise Error, "cannot parse user mcp.json (#{path}): #{e.message}"
    end
  end

  # Thor subcommand: clpr mcp ...
  class McpCLI < Thor
    class_option :no_color, type: :boolean, default: false

    desc "list", "List all MCP servers (user and plugin-provided)"
    def list = Mcp.list(State.load)

    desc "add NAME [-- CMD ARGS...] [--env KEY=VALUE] | --url URL | --config JSON",
         "Add an MCP server to your user config"
    option :url, desc: "Remote server URL"
    option :transport, desc: "Remote transport: http (default) or sse"
    option :env, repeatable: true, desc: "Environment variable KEY=VALUE (stdio only, repeatable)"
    option :config, desc: "Raw JSON server config object"
    def add(name, *command)
      Mcp.add(State.load, name, command, url: options[:url], transport: options[:transport],
              env: options[:env], config: options[:config])
    end

    desc "get NAME", "Show one MCP server's config, origin, and status"
    def get(name) = Mcp.get(State.load, name)

    desc "remove NAME", "Remove an MCP server from your user config"
    def remove(name) = Mcp.remove(State.load, name)

    desc "activate NAME", "Enable a user server or activate a plugin-provided one"
    def activate(name) = Mcp.activate(State.load, name)

    desc "deactivate NAME", "Disable a user server or deactivate a plugin-provided one"
    def deactivate(name) = Mcp.deactivate(State.load, name)
  end
end
