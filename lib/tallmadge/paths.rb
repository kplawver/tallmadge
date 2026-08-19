# frozen_string_literal: true

module Tallmadge
  # All paths root at Dir.home so tests and verification can sandbox by
  # overriding ENV["HOME"].
  module Paths
    SECTIONS = %w[skills agents tasks memories].freeze
    # OS-generated junk, never treated as content anywhere in ~/.agents.
    IGNORED_ENTRIES = [".DS_Store"].freeze

    module_function

    def tallmadge_home = File.join(Dir.home, ".tallmadge")
    def state_file = File.join(tallmadge_home, "state.json")
    def marketplaces_dir = File.join(tallmadge_home, "marketplaces")
    def store_dir = File.join(tallmadge_home, "store")
    def backups_dir = File.join(tallmadge_home, "backups")
    def cache_dir = File.join(tallmadge_home, "cache")
    def profiles_dir = File.join(tallmadge_home, "profiles")
    def profile_dir(name) = File.join(profiles_dir, name)
    def agents_home = File.join(Dir.home, ".agents")

    def agents_section(name) = File.join(agents_home, name)

    def plugin_dir(id) = File.join(store_dir, id)
    def marketplace_dir(name) = File.join(marketplaces_dir, name)
    def user_store_dir = File.join(store_dir, "user")

    # Creates all tallmadge dirs plus the four ~/.agents section dirs.
    # Idempotent; never touches existing files. Returns newly created dirs.
    def ensure_skeleton!
      created = []
      dirs = [tallmadge_home, marketplaces_dir, store_dir, backups_dir, cache_dir, profiles_dir,
              *SECTIONS.map { |s| agents_section(s) }]
      dirs.each do |dir|
        created << dir unless Dir.exist?(dir)
        FileUtils.mkdir_p(dir)
      end
      created
    end
  end
end
