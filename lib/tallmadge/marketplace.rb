# frozen_string_literal: true

module Tallmadge
  # Marketplace catalogs in the Claude/omp-compatible marketplace.json
  # format. Sources: owner/repo (github), git URL, local path, or a direct
  # URL to a marketplace.json.
  module Marketplace
    NAME_RE = /\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/.freeze

    module_function

    # ---- source classification ----------------------------------------------

    def classify(source)
      return :url if source.match?(%r{\Ahttps?://.*\.json\z})
      return :git if source.start_with?("git@", "ssh://", "file://") || source.end_with?(".git")
      return :git if source.match?(%r{\Ahttps?://})
      return :path if source.start_with?("/", "./", "~/") || Dir.exist?(source)
      return :github if source.match?(%r{\A[^/]+/[^/]+\z})

      raise Error, "cannot classify marketplace source: #{source.inspect}"
    end

    # ---- add -----------------------------------------------------------------

    def add(state, source)
      case classify(source)
      when :github then add_git(state, "https://github.com/#{source}.git",
                                { "type" => "github", "repo" => source }, source)
      when :git then add_git(state, source, { "type" => "git", "url" => source }, source)
      when :path then add_path(state, File.expand_path(source))
      when :url then add_url(state, source)
      end
    end

    def add_git(state, url, source_record, source_desc)
      Dir.mktmpdir("tallmadge-marketplace") do |tmp|
        clone_dir = File.join(tmp, "repo")
        Git.clone(url, clone_dir)
        catalog = read_catalog!(clone_dir, source_desc)
        validate_catalog!(catalog, source_desc)
        name = catalog["name"]
        if state.marketplaces.key?(name)
          state.profile_marketplaces << name unless state.profile_marketplaces.include?(name)
          state.save
          Reporter.ok "marketplace #{Reporter.name(name)} already added; included in profile #{state.active_profile_name}"
          return
        end

        FileUtils.mv(clone_dir, Paths.marketplace_dir(name))
        state.marketplaces[name] = {
          "source" => source_record,
          "path" => "marketplaces/#{name}",
          "sha" => Git.head_sha(Paths.marketplace_dir(name)),
          "updatedAt" => Time.now.utc.iso8601
        }
        state.profile_marketplaces << name unless state.profile_marketplaces.include?(name)
        state.save
        Reporter.ok "added marketplace #{Reporter.name(name)} " \
                    "(#{valid_entries(catalog).size} plugins, #{state.marketplaces[name]['sha'][0, 7]})"
      end
    end

    def add_path(state, dir)
      raise Error, "no such directory: #{dir}" unless Dir.exist?(dir)

      catalog = read_catalog!(dir, dir)
      validate_catalog!(catalog, dir)
      name = catalog["name"]
      if state.marketplaces.key?(name)
        state.profile_marketplaces << name unless state.profile_marketplaces.include?(name)
        state.save
        Reporter.ok "marketplace #{Reporter.name(name)} already added; included in profile #{state.active_profile_name}"
        return
      end

      state.marketplaces[name] = {
        "source" => { "type" => "path", "path" => dir },
        "path" => dir,
        "sha" => nil,
        "updatedAt" => Time.now.utc.iso8601
      }
      state.profile_marketplaces << name unless state.profile_marketplaces.include?(name)
      state.save
      Reporter.ok "added marketplace #{Reporter.name(name)} (path #{dir}, " \
                  "#{valid_entries(catalog).size} plugins)"
    end

    def add_url(state, url)
      body = Http.get(url)
      catalog = parse_json!(body, url)
      validate_catalog!(catalog, url)
      name = catalog["name"]
      if state.marketplaces.key?(name)
        state.profile_marketplaces << name unless state.profile_marketplaces.include?(name)
        state.save
        Reporter.ok "marketplace #{Reporter.name(name)} already added; included in profile #{state.active_profile_name}"
        return
      end

      dir = Paths.marketplace_dir(name)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "marketplace.json"), body)
      state.marketplaces[name] = {
        "source" => { "type" => "url", "url" => url },
        "path" => "marketplaces/#{name}",
        "sha" => nil,
        "updatedAt" => Time.now.utc.iso8601
      }
      state.profile_marketplaces << name unless state.profile_marketplaces.include?(name)
      state.save
      Reporter.ok "added marketplace #{Reporter.name(name)} (url, #{valid_entries(catalog).size} plugins)"
    end

    # ---- catalog access ------------------------------------------------------

    def catalog_dir(state, name)
      entry = marketplace_entry!(state, name)
      path = entry["path"]
      path.start_with?("/") ? path : File.join(Paths.tallmadge_home, path)
    end

    def load_catalog(state, name)
      entry = marketplace_entry!(state, name)
      if entry["source"]["type"] == "url"
        parse_json!(File.read(File.join(catalog_dir(state, name), "marketplace.json")), name)
      else
        read_catalog!(catalog_dir(state, name), name)
      end
    end

    def read_catalog!(dir, source_desc)
      path = Store.marketplace_catalog_path(dir)
      unless path
        raise Error, "no marketplace.json in #{source_desc} " \
                     "(looked in .claude-plugin/ and .omp-plugin/)"
      end

      parse_json!(File.read(path), source_desc)
    end

    def parse_json!(body, source_desc)
      JSON.parse(body)
    rescue JSON::ParserError => e
      raise Error, "invalid marketplace JSON from #{source_desc}: #{e.message}"
    end

    def validate_catalog!(catalog, source_desc)
      name = catalog["name"]
      unless name.is_a?(String) && name.match?(NAME_RE) && name.length <= 64
        raise Error, "#{source_desc}: invalid marketplace name #{name.inspect} " \
                     "(must match #{NAME_RE.source}, max 64 chars)"
      end

      owner = catalog["owner"]
      unless owner.is_a?(Hash) && owner["name"].is_a?(String) && !owner["name"].empty?
        raise Error, "#{source_desc}: marketplace is missing owner.name"
      end

      unless catalog["plugins"].is_a?(Array)
        raise Error, "#{source_desc}: marketplace is missing the plugins array"
      end
    end

    def valid_entries(catalog)
      catalog["plugins"].filter_map do |entry|
        if entry.is_a?(Hash) && entry["name"].is_a?(String) &&
           !entry["name"].empty? && entry["source"]
          entry
        else
          Reporter.warn "skipping invalid plugin entry in marketplace " \
                        "#{catalog['name']}: #{entry.inspect[0, 80]}"
          nil
        end
      end
    end

    def marketplace_entry!(state, name)
      entry = state.marketplaces[name]
      unless entry
        known = state.marketplaces.keys
        msg = "unknown marketplace '#{name}'"
        msg += " (added: #{known.join(', ')})" unless known.empty?
        raise Error, msg
      end

      entry
    end


    # ---- list / update / remove -----------------------------------------------

    def list(state)
      names = state.profile_marketplaces.select { |n| state.marketplaces.key?(n) }
      if names.empty?
        Reporter.info "no marketplaces added"
        return
      end

      rows = names.map do |name|
        entry = state.marketplaces[name]
        catalog = load_catalog(state, name)
        count = valid_entries(catalog).size.to_s
        [name, source_summary(entry["source"]), count,
         (entry["sha"] || "-")[0, 7], entry["updatedAt"].to_s]
      rescue Error => e
        [name, source_summary(entry["source"]), "?", "-", e.message[0, 40]]
      end
      Reporter.table(rows, %w[name source plugins sha updated])
    end

    def update(state, name = nil, strict: false)
      if name
        marketplace_entry!(state, name)
        update_one(state, name, strict: true)
      else
        state.marketplaces.each_key { |n| update_one(state, n, strict: strict) }
      end
    end

    def update_one(state, name, strict: false)
      entry = marketplace_entry!(state, name)
      case entry["source"]["type"]
      when "github", "git" then update_git(state, name, entry)
      when "url" then update_url(state, name, entry)
      when "path" then update_path(state, name, entry)
      end
    rescue Error => e
      raise if strict

      Reporter.warn "#{name}: update failed (#{e.message})"
    end

    def update_git(state, name, entry)
      dir = catalog_dir(state, name)
      old_sha = entry["sha"]
      Git.pull(dir)
      new_sha = Git.head_sha(dir)
      entry["sha"] = new_sha
      entry["updatedAt"] = Time.now.utc.iso8601
      state.save
      if old_sha == new_sha
        Reporter.info "unchanged #{name} (#{new_sha[0, 7]})"
      else
        Reporter.ok "#{name} #{(old_sha || 'new')[0, 7]}→#{new_sha[0, 7]}"
      end
    end

    def update_url(state, name, entry)
      url = entry["source"]["url"]
      body = Http.get(url)
      catalog = parse_json!(body, url)
      validate_catalog!(catalog, url)

      file = File.join(catalog_dir(state, name), "marketplace.json")
      old = File.exist?(file) ? File.read(file) : nil
      if old == body
        Reporter.info "unchanged #{name}"
      else
        File.write(file, body)
        entry["updatedAt"] = Time.now.utc.iso8601
        state.save
        Reporter.ok "#{name} refreshed"
      end
    end

    def update_path(state, name, entry)
      catalog = read_catalog!(entry["source"]["path"], name)
      validate_catalog!(catalog, name)
      entry["updatedAt"] = Time.now.utc.iso8601
      state.save
      Reporter.ok "#{name} re-read (#{valid_entries(catalog).size} plugins)"
    end

    def remove(state, name)
      entry = marketplace_entry!(state, name)
      state.profile_marketplaces.delete(name)
      other_profiles_include = state.profiles.values.any? do |prof|
        Array(prof["marketplaces"]).include?(name)
      end

      unless other_profiles_include
        dir = catalog_dir(state, name)
        if entry["source"]["type"] != "path" && dir.start_with?(Paths.tallmadge_home)
          FileUtils.rm_rf(dir)
        end
        state.marketplaces.delete(name)

        orphaned = state.plugins.count do |_, plugin|
          src = plugin["source"]
          src["type"] == "marketplace" && src["marketplace"] == name
        end
        if orphaned.positive?
          Reporter.warn "#{orphaned} installed plugin(s) came from #{name}; they remain " \
                        "installed but update checks for them are limited"
        end
      end

      state.save
      Reporter.ok "removed marketplace #{name}"
    end

    def source_summary(source)
      case source["type"]
      when "github" then "github #{source['repo']}"
      when "git" then "git #{source['url']}"
      when "path" then "path #{source['path']}"
      when "url" then "url #{source['url']}"
      else "unknown"
      end
    end

    # ---- plugin materialization (used by Installer) ----------------------------

    # Returns [plugin_dir, sha] — a directory holding the plugin content.
    def materialize(state, marketplace_name, entry, tmpdir)
      source = entry["source"]

      case source
      when String
        dir = File.join(catalog_root(state, marketplace_name), *relative_parts(source))
        raise Error, "plugin path #{dir} does not exist in marketplace #{marketplace_name}" unless Dir.exist?(dir)

        [dir, state.marketplaces[marketplace_name]["sha"]]
      when Hash
        materialize_hash_source(source, tmpdir)
      else
        raise Error, "unsupported plugin source in marketplace #{marketplace_name}: #{source.inspect}"
      end
    end

    # "./relpath" relative to the marketplace root, minus the ./ prefix.
    def relative_parts(source_string)
      rel = source_string.sub(%r{\A\./}, "")
      rel.empty? ? [] : [rel]
    end

    # Marketplace clone/dir root, with metadata.pluginRoot prepended when set.
    def catalog_root(state, marketplace_name)
      base = catalog_dir(state, marketplace_name)
      catalog = load_catalog(state, marketplace_name)
      plugin_root = catalog.dig("metadata", "pluginRoot")
      plugin_root && !plugin_root.empty? ? File.join(base, plugin_root) : base
    end

    def materialize_hash_source(source, tmpdir)
      kind = source["source"] || source["type"]
      clone_dir = File.join(tmpdir, "repo")

      case kind
      when "github"
        Git.clone("https://github.com/#{source['repo']}.git", clone_dir,
                  ref: source["ref"] || source["sha"])
        [clone_dir, Git.head_sha(clone_dir)]
      when "url"
        Git.clone(source["url"], clone_dir, ref: source["ref"] || source["sha"])
        [clone_dir, Git.head_sha(clone_dir)]
      when "git-subdir"
        Git.clone(source["url"], clone_dir, ref: source["ref"] || source["sha"])
        subdir = File.join(clone_dir, source["path"].to_s)
        raise Error, "git-subdir path #{source['path']} not found in #{source['url']}" unless Dir.exist?(subdir)

        [subdir, Git.head_sha(clone_dir)]
      when "npm"
        raise Error, "npm plugin sources are not supported"
      else
        raise Error, "unknown plugin source type: #{kind.inspect}"
      end
    end

    # ---- search ------------------------------------------------------------------

    def search(state, query)
      q = query.to_s.downcase
      rows = []

      state.profile_marketplaces.each do |name|
        next unless state.marketplaces.key?(name)

        catalog = load_catalog(state, name)
        valid_entries(catalog).each do |entry|
          fields = [entry["name"], entry["description"], entry["category"], *Array(entry["tags"])]
          next unless matches?(q, fields)

          rows << ["#{entry['name']}@#{name}",
                   truncate(entry["description"].to_s, 60),
                   (entry["category"] || Array(entry["tags"]).join(",")).to_s]
        end
      rescue Error
        next
      end

      if defined?(Tallmadge::Hub)
        Array(Hub.cached_catalog_items).each do |item|
          fields = [item["id"], item["name"], item["summary"], *Array(item["tags"])]
          next unless matches?(q, fields)

          rows << ["hub:#{item['id']}", truncate(item["summary"].to_s, 60),
                   Array(item["tags"]).join(",")]
        end
      end

      if rows.empty?
        Reporter.info(query ? "no matches for #{query.inspect}" : "nothing to search")
      else
        Reporter.table(rows, %w[source description tags])
      end
    end

    def matches?(query, fields)
      return true if query.empty?

      fields.compact.any? { |field| field.to_s.downcase.include?(query) }
    end

    def truncate(text, max)
      text.length > max ? "#{text[0, max - 1]}…" : text
    end
  end

  # Thor subcommand: clpr marketplace ...
  class MarketplaceCLI < Thor
    class_option :no_color, type: :boolean, default: false

    desc "add SOURCE", "Add a marketplace (owner/repo, git URL, path, or catalog URL)"
    def add(source)
      Marketplace.add(State.load, source)
    end

    desc "list", "List added marketplaces"
    def list
      Marketplace.list(State.load)
    end

    desc "update [NAME]", "Refresh one marketplace (or all)"
    def update(name = nil)
      Marketplace.update(State.load, name)
    end

    desc "remove NAME", "Remove a marketplace (installed plugins remain)"
    def remove(name)
      Marketplace.remove(State.load, name)
    end
  end
end
