# frozen_string_literal: true

module Tallmadge
  # `clpr install <spec>` dispatch. Spec forms:
  #   /abs/path, ./rel, ~/path            -> local dir copy
  #   https://....git, git@..., owner/repo-> git clone
  #   plugin@marketplace                  -> marketplace catalog entry (Step 4)
  #   bare name                           -> hub bundle id, then marketplace
  #                                          plugin name across catalogs (Step 5)
  class Installer
    MARKETPLACE_SPEC = /\A[A-Za-z0-9._-]+@[A-Za-z0-9._-]+\z/.freeze

    attr_reader :state

    def initialize(state)
      @state = state
    end

    def install(spec, as: nil, force: false)
      return install_from_marketplace(spec, as: as, force: force) if spec.match?(MARKETPLACE_SPEC)

      case classify(spec)
      when :path then install_path(spec, as: as, force: force)
      when :git then install_git(spec, as: as, force: force)
      else install_bare(spec, as: as, force: force)
      end
    end

    def classify(spec)
      return :path if spec.start_with?("/", "./", "~/")
      return :git if spec.end_with?(".git") || spec.start_with?("git@", "ssh://")
      return :git if spec.start_with?("http://", "https://", "file://")
      return :github if spec.match?(%r{\A[^/]+/[^/]+\z}) && !Dir.exist?(spec)

      :bare
    end

    def install_path(spec, as: nil, force: false)
      src = File.expand_path(spec)
      raise Error, "no such directory: #{src}" unless Dir.exist?(src)

      id = as || Store.derive_id(src)
      prior = prepare_install(id, force)
      Store.copy_into(src, Paths.plugin_dir(id))
      finish(id, { "type" => "path", "path" => src }, prior)
    end

    def install_git(spec, as: nil, force: false, ref: nil, url_override: nil)
      url = url_override || git_url(spec)
      id = as || Store.derive_id(url)
      prior = prepare_install(id, force)
      sha = nil

      Dir.mktmpdir("tallmadge-install") do |tmp|
        clone_dir = File.join(tmp, "repo")
        Git.clone(url, clone_dir, ref: ref)
        sha = Git.head_sha(clone_dir)
        if Store.marketplace_catalog_path(clone_dir)
          raise Error, "#{spec} is a marketplace, use: clpr marketplace add #{spec}"
        end

        Store.copy_into(clone_dir, Paths.plugin_dir(id))
      end

      finish(id, { "type" => "git", "url" => url, "ref" => ref || "HEAD", "sha" => sha }, prior)
    end

    # plugin@marketplace — resolve the catalog entry and materialize it.
    def install_from_marketplace(spec, as: nil, force: false)
      plugin_name, marketplace_name = spec.split("@", 2)
      Marketplace.marketplace_entry!(@state, marketplace_name)
      catalog = Marketplace.load_catalog(@state, marketplace_name)
      entry = Marketplace.valid_entries(catalog).find { |e| e["name"] == plugin_name }
      unless entry
        raise Error, "plugin '#{plugin_name}' not found in marketplace '#{marketplace_name}'"
      end

      id = as || "#{plugin_name}@#{marketplace_name}"
      prior = prepare_install(id, force)
      sha = nil
      Dir.mktmpdir("tallmadge-marketplace-plugin") do |tmp|
        source_dir, sha = Marketplace.materialize(@state, marketplace_name, entry, tmp)
        Store.copy_into(source_dir, Paths.plugin_dir(id))
      end

      version = entry["version"] || plugin_json_version(id) || (sha && sha[0, 7])
      source = { "type" => "marketplace", "marketplace" => marketplace_name,
                 "plugin" => plugin_name, "sha" => sha, "version" => version }
      finish(id, source, prior)
    end

    def plugin_json_version(id)
      %w[.claude-plugin .omp-plugin].each do |meta|
        path = File.join(Paths.plugin_dir(id), meta, "plugin.json")
        next unless File.file?(path)

        data = JSON.parse(File.read(path)) rescue {}
        return data["version"] if data["version"]
      end
      nil
    end

    # Bare name: hub bundle id first, then marketplace plugin name across
    # all added marketplaces.
    def install_bare(spec, as: nil, force: false)
      begin
        record = Hub.catalog
        if Hub.items(record).any? { |i| i["id"] == spec }
          return Hub.install(@state, spec, as: as, force: force)
        end
      rescue Error => e
        Reporter.warn "hub catalog unavailable (#{e.message}); searching marketplaces only"
      end

      matches = []
      @state.marketplaces.each_key do |marketplace_name|
        catalog = Marketplace.load_catalog(@state, marketplace_name) rescue next
        Marketplace.valid_entries(catalog).each do |entry|
          matches << "#{entry['name']}@#{marketplace_name}" if entry["name"] == spec
        end
      end

      case matches.size
      when 0
        raise Error, "no hub bundle or marketplace plugin named #{spec.inspect}"
      when 1
        install_from_marketplace(matches.first, as: as, force: force)
      else
        raise Error, "#{spec.inspect} is ambiguous — pick one: #{matches.join(', ')}"
      end
    end

    def git_url(spec)
      return "https://github.com/#{spec}.git" if classify(spec) == :github

      spec
    end

    # Errors on an existing id unless force; with force, deactivates and
    # removes the old install and returns its active component names so the
    # new install can re-activate matching ones.
    def prepare_install(id, force)
      existing = @state.plugins[id]
      return nil unless existing

      unless force
        raise Error, "plugin '#{id}' is already installed (use --force to replace)"
      end

      prior = active_component_pairs(existing)
      Activator.new(@state).deactivate(id)
      FileUtils.rm_rf(Paths.plugin_dir(id))
      @state.plugins.delete(id)
      @state.mcp_origins.delete_if { |_, origin| origin == id }
      prior
    end

    def active_component_pairs(entry)
      pairs = []
      (entry["components"] || {}).each do |section, items|
        next if items.nil?

        if section == "agentsMd"
          pairs << ["agentsMd", nil] if items["active"]
          next
        end
        items.each { |name, info| pairs << [section, name] if info["active"] }
      end
      pairs
    end

    # Every [section, name] pair present in an entry, regardless of active
    # state (used to decide which prior activations survive a reinstall).
    def self.available_pairs(entry)
      pairs = []
      (entry["components"] || {}).each do |section, items|
        next if items.nil?

        if section == "agentsMd"
          pairs << ["agentsMd", nil]
          next
        end
        items.each_key { |name| pairs << [section, name] }
      end
      pairs
    end

    def finish(id, source, prior_active)
      dir = Paths.plugin_dir(id)
      scan = Store.scan(dir)
      now = Time.now.utc.iso8601

      @state.plugins[id] = {
        "displayName" => scan["displayName"],
        "description" => scan["description"],
        "source" => source,
        "installedAt" => now,
        "updatedAt" => now,
        "components" => scan["components"]
      }
      @state.save
      report_install(id, @state.plugins[id])

      if prior_active && !prior_active.empty?
        available = Installer.available_pairs(@state.plugins[id])
        restorable = prior_active.select { |pair| available.include?(pair) }
        (prior_active - restorable).each do |section, name|
          Reporter.warn "component #{section}#{name ? ":#{name}" : ''} no longer exists " \
                        "after reinstall; not re-activated"
        end
        if restorable.empty?
          @state.save
        else
          Activator.new(@state).activate(id, only: restorable, force: true)
        end
      end
      id
    end

    def report_install(id, entry)
      src = entry["source"]
      suffix = case src["type"]
               when "git" then " (git #{(src['sha'] || 'HEAD')[0, 7]})"
               when "path" then " (path #{src['path']})"
               when "marketplace" then " (marketplace #{src['marketplace']})"
               when "hub" then " (hub bundle v#{src['bundleVersion']})"
               else ""
               end
      Reporter.ok "installed #{Reporter.name(id)}#{suffix}"

      rows = []
      entry["components"].each do |section, items|
        next if items.nil? || items.empty?

        names = section == "agentsMd" ? ["agents.md"] : items.keys
        rows << [section, names.join(", ")]
      end
      if rows.empty?
        Reporter.warn "no .agents components found in #{id}"
      else
        Reporter.table(rows)
      end
    end
  end
end
