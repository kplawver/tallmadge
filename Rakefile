# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.pattern = "test/**/*_test.rb"
  t.verbose = false
end

task default: :test

namespace :homebrew do
  desc "Generate Homebrew formula in ../homebrew-tap/tallmadge.rb for current version"
  task :formula do
    require "digest"
    require "open-uri"
    require_relative "lib/tallmadge"

    version = Tallmadge::VERSION
    repo_url = "https://github.com/kplawver/tallmadge"
    tar_url = "#{repo_url}/archive/refs/tags/#{version}.tar.gz"

    puts "Fetching archive to calculate sha256: #{tar_url}..."
    tar_sha256 = begin
      URI.open(tar_url) { |f| Digest::SHA256.hexdigest(f.read) }
    rescue StandardError => e
      warn "Warning: Could not fetch from GitHub (#{e.message}). Falling back to local git archive or empty placeholder."
      # Fallback to local git tag if archive not on remote yet
      begin
        tar_data = IO.popen(["git", "archive", "--format=tar.gz", "--prefix=tallmadge-#{version}/", version], &:read)
        Digest::SHA256.hexdigest(tar_data) unless tar_data.empty?
      rescue StandardError
        nil
      end
    end

    raise "Could not compute SHA256 for #{version}" unless tar_sha256

    # Helper to fetch gem sha256 from rubygems
    fetch_gem_sha = lambda do |gem_name, gem_ver|
      gem_url = "https://rubygems.org/downloads/#{gem_name}-#{gem_ver}.gem"
      URI.open(gem_url) { |f| Digest::SHA256.hexdigest(f.read) }
    end

    rainbow_ver = "3.1.1"
    thor_ver = "1.5.0"

    rainbow_sha = fetch_gem_sha.call("rainbow", rainbow_ver)
    thor_sha = fetch_gem_sha.call("thor", thor_ver)

    formula_content = <<~RUBY
      class Tallmadge < Formula
        desc "CLI manager for ~/.agents/ and AI coding harness extensions"
        homepage "#{repo_url}"
        url "#{tar_url}"
        sha256 "#{tar_sha256}"
        license "MIT"

        depends_on "ruby"
        uses_from_macos "git"

        resource "rainbow" do
          url "https://rubygems.org/downloads/rainbow-#{rainbow_ver}.gem"
          sha256 "#{rainbow_sha}"
        end

        resource "thor" do
          url "https://rubygems.org/downloads/thor-#{thor_ver}.gem"
          sha256 "#{thor_sha}"
        end

        def install
          ENV["GEM_HOME"] = libexec

          resources.each do |r|
            r.verify_download_integrity(r.fetch)
            system "gem", "install", r.cached_download,
                   "--no-document",
                   "--ignore-dependencies",
                   "--install-dir", libexec
          end

          system "gem", "build", "tallmadge.gemspec"
          system "gem", "install", "tallmadge-\#{version}.gem",
                 "--no-document",
                 "--ignore-dependencies",
                 "--install-dir", libexec

          bin.install libexec/"bin/clpr"
          bin.env_script_all_files(libexec/"bin", GEM_HOME: ENV["GEM_HOME"])
        end

        test do
          assert_match "clpr \#{version}", shell_output("\#{bin}/clpr version")
        end
      end
    RUBY

    tap_dir = File.expand_path("../homebrew-tap", __dir__)
    dest_path = File.join(tap_dir, "tallmadge.rb")

    if Dir.exist?(tap_dir)
      File.write(dest_path, formula_content)
      puts "✓ Successfully wrote formula to #{dest_path}"
    else
      puts "Homebrew tap directory not found at #{tap_dir}. Generated formula:\n\n#{formula_content}"
    end
  end
end
