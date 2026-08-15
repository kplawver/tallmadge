# frozen_string_literal: true

module Tallmadge
  # .agents Hub: catalog of downloadable .dotagents bundles (JSON).
  # Bundles are converted into a normal plugin tree in the store.
  module Hub
    CATALOG_URL = "https://raw.githubusercontent.com/aj47/dotagents-hub/main/catalog.json"
    BUNDLES_BASE = "https://raw.githubusercontent.com/aj47/dotagents-hub/main/bundles"
    CACHE_TTL_SECONDS = 24 * 60 * 60

    module_function

    def cache_path
      File.join(Paths.cache_dir, "hub-catalog.json")
    end

    # Returns {"fetchedAt" => ..., "catalog" => <raw catalog>}, fetching and
    # caching when the cache is missing or older than 24h (force: refresh).
    def catalog(force: false)
      record = read_cache unless force
      return record if record

      body = Http.get(CATALOG_URL)
      data =
        begin
          JSON.parse(body)
        rescue JSON::ParserError => e
          raise Error, "invalid hub catalog JSON from #{CATALOG_URL}: #{e.message}"
        end

      record = { "fetchedAt" => Time.now.utc.iso8601, "catalog" => data }
      FileUtils.mkdir_p(Paths.cache_dir)
      File.write(cache_path, JSON.pretty_generate(record))
      record
    end

    def read_cache
      return nil unless File.exist?(cache_path)

      record = JSON.parse(File.read(cache_path)) rescue nil
      return nil unless record.is_a?(Hash) && record["fetchedAt"] && record["catalog"]

      fetched = Time.parse(record["fetchedAt"]) rescue Time.at(0)
      (Time.now - fetched) < CACHE_TTL_SECONDS ? record : nil
    end

    # Catalog items list; tolerates both {items: [...]} and a bare array.
    def items(record = nil)
      record ||= catalog
      raw = record["catalog"]
      raw.is_a?(Hash) ? Array(raw["items"]) : Array(raw)
    end

    # Cache-only items for search (no network).
    def cached_catalog_items
      record = read_cache
      record ? items(record) : nil
    end

    def find_item!(bundle_id, record = nil)
      item = items(record).find { |i| i["id"] == bundle_id }
      raise Error, "hub bundle '#{bundle_id}' not found (see: clpr hub list)" unless item

      item
    end

    # ---- commands --------------------------------------------------------------

    def list
      record = catalog
      rows = items(record).map do |item|
        [item["id"].to_s, item["name"].to_s,
         Marketplace.truncate(item["summary"].to_s, 50),
         counts_summary(item["componentCounts"]),
         Array(item["tags"]).join(",")]
      end
      Reporter.table(rows, %w[id name summary components tags])
    end

    COUNT_LABELS = {
      "agentProfiles" => "agents", "skills" => "skills", "mcpServers" => "mcp",
      "repeatTasks" => "tasks", "memories" => "memories"
    }.freeze

    def counts_summary(counts)
      return "" unless counts.is_a?(Hash)

      counts.filter_map do |key, value|
        value.to_i.positive? ? "#{value} #{COUNT_LABELS[key] || key}" : nil
      end.join(" · ")
    end

    # Re-fetch catalog and diff against installed hub plugins (report only;
    # apply via `clpr update --apply`).
    def update(state)
      record = catalog(force: true)
      Reporter.ok "hub catalog refreshed (#{items(record).size} bundles)"

      hub_plugins = state.plugins.select { |_, e| e.dig("source", "type") == "hub" }
      if hub_plugins.empty?
        Reporter.info "no hub bundles installed"
        return
      end

      rows = hub_plugins.map do |id, entry|
        src = entry["source"]
        item = items(record).find { |i| i["id"] == src["bundleId"] }
        if item.nil?
          [id, "v#{src['bundleVersion']}", "-", "missing from catalog"]
        else
          installed_v = src["bundleVersion"].to_i
          latest_v = item["bundleVersion"].to_i
          stale = latest_v > installed_v || item["updatedAt"] != src["updatedAt"]
          status = stale ? Rainbow("update available").yellow : Rainbow("up to date").faint
          [id, "v#{installed_v}", "v#{latest_v}", status.to_s]
        end
      end
      Reporter.table(rows, %w[id installed latest status])
    end

    # ---- bundle install ----------------------------------------------------------

    def install(state, bundle_id, as: nil, force: false)
      record = catalog
      item = find_item!(bundle_id, record)
      installer = Installer.new(state)
      id = as || bundle_id
      prior = installer.prepare_install(id, force)

      file_name = item.dig("artifact", "fileName") || "#{bundle_id}.dotagents"
      # The raw GitHub path is deterministic; the hub host serves HTML for
      # some artifact URLs, so artifact.url is intentionally ignored.
      url = "#{BUNDLES_BASE}/#{file_name}"
      bundle = fetch_bundle(url)

      dir = Paths.plugin_dir(id)
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      write_bundle_tree(bundle, dir)

      source = {
        "type" => "hub", "bundleId" => item["id"], "url" => url,
        "bundleVersion" => item["bundleVersion"], "updatedAt" => item["updatedAt"]
      }
      installer.finish(id, source, prior)
    end

    def fetch_bundle(url)
      body = Http.get(url)
      JSON.parse(body)
    rescue JSON::ParserError => e
      raise Error, "invalid bundle JSON from #{url}: #{e.message}"
    end

    # Converts bundle JSON into a .agents plugin tree.
    def write_bundle_tree(bundle, dir)
      manifest = bundle["manifest"] || {}
      write_plugin_metadata(dir, manifest)
      write_agent_profiles(dir, Array(bundle["agentProfiles"]))
      write_skills(dir, Array(bundle["skills"]))
      write_tasks(dir, Array(bundle["repeatTasks"]))
      write_memories(dir, Array(bundle["memories"]))
      write_mcp(dir, bundle["mcpServers"])
    end

    def write_plugin_metadata(dir, manifest)
      meta_dir = File.join(dir, ".claude-plugin")
      FileUtils.mkdir_p(meta_dir)
      summary = manifest.dig("publicMetadata", "summary")
      plugin_json = {
        "name" => manifest["name"],
        "description" => manifest["description"] || summary
      }.compact
      File.write(File.join(meta_dir, "plugin.json"), JSON.pretty_generate(plugin_json) + "\n")
    end

    def write_agent_profiles(dir, profiles)
      profiles.each do |profile|
        next unless profile.is_a?(Hash) && profile["id"]

        fm = {
          "id" => profile["id"],
          "name" => profile["displayName"] || profile["name"],
          "description" => profile["description"],
          "role" => profile["role"],
          "enabled" => profile.fetch("enabled", true)
        }
        connection_type = profile.dig("connection", "type")
        fm["connection-type"] = connection_type if connection_type
        body = profile["systemPrompt"].to_s
        guidelines = profile["guidelines"]
        body += "\n\n## Guidelines\n#{guidelines}" if guidelines && !guidelines.to_s.strip.empty?

        write_component(dir, "agents", profile["id"], Frontmatter.serialize(fm.compact, body))
      end
    end

    def write_skills(dir, skills)
      skills.each do |skill|
        next unless skill.is_a?(Hash) && skill["id"]

        instructions = skill["instructions"].to_s
        content =
          if instructions.start_with?("---")
            instructions
          else
            Frontmatter.serialize(
              { "name" => skill["name"] || skill["id"],
                "description" => skill["description"] }.compact,
              instructions
            )
          end
        write_component(dir, "skills", skill["id"], content)
      end
    end

    def write_tasks(dir, tasks)
      tasks.each do |task|
        next unless task.is_a?(Hash) && task["id"]

        fm = {
          "kind" => "task",
          "id" => task["id"],
          "name" => task["name"],
          "intervalMinutes" => task["intervalMinutes"],
          "enabled" => task.fetch("enabled", true),
          "runOnStartup" => task["runOnStartup"]
        }
        write_component(dir, "tasks", task["id"], Frontmatter.serialize(fm.compact, task["prompt"].to_s))
      end
    end

    # Entry shape is unverified upstream (usually empty): accept
    # {id,title,content,...} objects; plain strings become the body with an
    # id derived from the index.
    def write_memories(dir, memories)
      memories.each_with_index do |memory, index|
        if memory.is_a?(String)
          memory_id = "memory-#{index + 1}"
          fm = { "id" => memory_id, "importance" => "medium" }
          body = memory
        elsif memory.is_a?(Hash)
          memory_id = memory["id"] || "memory-#{index + 1}"
          fm = {
            "id" => memory_id,
            "title" => memory["title"],
            "importance" => memory["importance"] || "medium"
          }
          tags = memory["tags"]
          fm["tags"] = Array(tags).join(", ") if tags && !Array(tags).empty?
          body = memory["content"].to_s
        else
          next
        end

        path = File.join(dir, "memories", "#{memory_id}.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, Frontmatter.serialize(fm.compact, body))
      end
    end

    # Accepts an object map or an array of {name/id, ...} objects (the shape
    # shipped by the hub); normalizes to {"mcpServers" => {name => config}}.
    def write_mcp(dir, raw)
      servers = normalize_mcp_servers(raw)
      return if servers.empty?

      File.write(File.join(dir, "mcp.json"),
                 JSON.pretty_generate({ "mcpServers" => servers }) + "\n")
    end

    def normalize_mcp_servers(raw)
      case raw
      when Hash then raw
      when Array
        raw.each_with_object({}) do |server, map|
          next unless server.is_a?(Hash)

          name = server["name"] || server["id"]
          next unless name

          map[name] = server.reject { |key, _| %w[name id].include?(key) }
        end
      else
        {}
      end
    end

    def write_component(dir, section, name, content)
      file_name =
        case section
        when "skills" then "SKILL.md"
        when "agents" then "agent.md"
        when "tasks" then "task.md"
        end
      path = File.join(dir, section, name, file_name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content.end_with?("\n") ? content : content + "\n")
    end
  end

  # Thor subcommand: clpr hub ...
  class HubCLI < Thor
    class_option :no_color, type: :boolean, default: false

    desc "list", "List hub bundles"
    def list
      Hub.list
    end

    desc "update", "Refresh the hub catalog and report bundle updates"
    def update
      Hub.update(State.load)
    end

    desc "install BUNDLE_ID", "Install a hub bundle"
    option :as, desc: "Install under this plugin id"
    option :force, type: :boolean, desc: "Replace an existing install with the same id"
    def install(bundle_id)
      Hub.install(State.load, bundle_id, as: options[:as], force: options[:force])
    end
  end
end
