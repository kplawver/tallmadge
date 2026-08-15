# frozen_string_literal: true

module Tallmadge
  # Update checking and applying. `clpr update` reports; `--apply`
  # reinstalls in place, preserving active components whose names survive.
  module Updater
    MARKETPLACE_STALE_AFTER = 24 * 60 * 60

    module_function

    # statuses: :current | :outdated | :unknown | :manual
    def run(state, id: nil, apply: false)
      plugins =
        if id
          entry = state.plugins[id]
          unless entry
            raise Error, "unknown plugin '#{id}' (installed: #{state.plugins.keys.join(', ')})"
          end

          { id => entry }
        else
          state.plugins
        end

      if plugins.empty?
        Reporter.info "no plugins installed"
        return
      end

      refresh_stale_marketplaces(state, plugins)

      rows = []
      outdated = []
      plugins.each do |plugin_id, entry|
        status, latest = check(state, entry)
        outdated << plugin_id if status == :outdated
        rows << row_for(plugin_id, entry, status, latest)
      end
      Reporter.table(rows, %w[id installed latest status])

      return unless apply

      if outdated.empty?
        Reporter.info "nothing to apply"
        return
      end
      apply_updates(state, outdated)
    end

    def row_for(id, entry, status, latest)
      installed = installed_label(entry)
      status_text =
        case status
        when :current then Rainbow("up to date").faint.to_s
        when :outdated then Rainbow("update available").yellow.to_s
        when :unknown then Rainbow("unknown").yellow.to_s
        when :manual then Rainbow("local path — update manually").faint.to_s
        end
      [id, installed, latest.to_s.empty? ? "-" : latest.to_s, status_text]
    end

    def installed_label(entry)
      src = entry["source"]
      case src["type"]
      when "git" then (src["sha"] || "HEAD")[0, 7]
      when "hub" then "v#{src['bundleVersion']}"
      when "marketplace" then src["version"] || (src["sha"] || "-")[0, 7]
      else "-"
      end
    end

    def refresh_stale_marketplaces(state, plugins)
      used = plugins.filter_map do |_, entry|
        entry.dig("source", "marketplace") if entry.dig("source", "type") == "marketplace"
      end.uniq

      used.each do |name|
        entry = state.marketplaces[name]
        next unless entry

        updated = Time.parse(entry["updatedAt"]) rescue Time.at(0)
        Marketplace.update_one(state, name) if Time.now - updated > MARKETPLACE_STALE_AFTER
      end
    end

    # Returns [status, latest_label].
    def check(state, entry)
      case entry.dig("source", "type")
      when "git" then check_git(entry)
      when "marketplace" then check_marketplace(state, entry)
      when "hub" then check_hub(entry)
      when "path" then [:manual, nil]
      else [:unknown, nil]
      end
    end

    def check_git(entry)
      src = entry["source"]
      ref = src["ref"].to_s.empty? || src["ref"] == "HEAD" ? nil : src["ref"]
      latest = Git.ls_remote_sha(src["url"], ref)
      [latest == src["sha"] ? :current : :outdated, latest[0, 7]]
    rescue Error => e
      Reporter.warn "git check failed for #{src['url']}: #{e.message.lines.first&.strip}"
      [:unknown, nil]
    end

    def check_marketplace(state, entry)
      src = entry["source"]
      catalog = Marketplace.load_catalog(state, src["marketplace"])
      mp_entry = Marketplace.valid_entries(catalog).find { |e| e["name"] == src["plugin"] }
      return [:unknown, nil] unless mp_entry

      latest_version = mp_entry["version"]
      if version_newer?(src["version"], latest_version)
        [:outdated, latest_version || "-"]
      elsif latest_version.nil? && src["sha"] && state.marketplaces[src["marketplace"]]
        # Fall back to marketplace sha drift when no versions are published.
        current_sha = state.marketplaces[src["marketplace"]]["sha"]
        current_sha && src["sha"] != current_sha ? [:outdated, current_sha[0, 7]] : [:current, src["sha"].to_s[0, 7]]
      else
        [:current, latest_version || src["version"] || "-"]
      end
    rescue Error => e
      Reporter.warn "marketplace check failed for #{entry['displayName']}: #{e.message}"
      [:unknown, nil]
    end

    def check_hub(entry)
      src = entry["source"]
      record = Hub.catalog
      item = Hub.items(record).find { |i| i["id"] == src["bundleId"] }
      return [:unknown, nil] unless item

      stale = item["bundleVersion"].to_i > src["bundleVersion"].to_i ||
              item["updatedAt"] != src["updatedAt"]
      [stale ? :outdated : :current, "v#{item['bundleVersion']}"]
    rescue Error
      [:unknown, nil]
    end

    def version_newer?(installed, latest)
      return false if latest.nil?
      return true if installed.nil?

      a = parse_semver(installed)
      b = parse_semver(latest)
      if a && b
        (a <=> b).negative?
      else
        installed.to_s != latest.to_s
      end
    end

    def parse_semver(str)
      m = str.to_s.match(/\A(\d+)\.(\d+)\.(\d+)/)
      m && [m[1].to_i, m[2].to_i, m[3].to_i]
    end

    # Reinstall each outdated plugin in place through its original source.
    def apply_updates(state, ids)
      ids.each do |id|
        entry = state.plugins[id]
        src = entry["source"]
        Reporter.info "updating #{id}…"
        installer = Installer.new(state)
        case src["type"]
        when "git"
          ref = src["ref"].to_s.empty? || src["ref"] == "HEAD" ? nil : src["ref"]
          installer.install_git(src["url"], as: id, force: true, ref: ref,
                                                url_override: src["url"])
        when "marketplace"
          installer.install_from_marketplace("#{src['plugin']}@#{src['marketplace']}",
                                             as: id, force: true)
        when "hub"
          Hub.install(state, src["bundleId"], as: id, force: true)
        else
          Reporter.warn "#{id}: cannot auto-update #{src['type']} source"
        end
      rescue Error => e
        Reporter.err "#{id}: update failed (#{e.message})"
      end
    end
  end
end
