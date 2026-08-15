# frozen_string_literal: true

module Tallmadge
  # Thin wrapper around the git binary. Every failure raises Tallmadge::Error
  # with the command and captured output.
  module Git
    module_function

    def clone(url, dir, ref: nil)
      if ref && ref.match?(/\A[0-9a-f]{40}\z/)
        # --branch cannot address a sha; clone and detach.
        run("git", "clone", url, dir)
        run("git", "-C", dir, "checkout", "--detach", ref)
      else
        args = ["git", "clone", "--depth", "1"]
        args += ["--branch", ref] if ref
        run(*args, url, dir)
      end
      dir
    end

    def head_sha(dir)
      run("git", "-C", dir, "rev-parse", "HEAD").strip
    end

    # First column of the first ls-remote line. ref nil -> HEAD.
    def ls_remote_sha(url, ref = nil)
      out = run("git", "ls-remote", url, ref || "HEAD")
      first = out.lines.first
      if first.nil? || first.strip.empty?
        raise Error, "git ls-remote #{url} returned no refs"
      end

      first.split(/\s+/).first
    end

    def pull(dir)
      run("git", "-C", dir, "pull", "--ff-only")
    end

    def run(*cmd)
      out, err, status = Open3.capture3(*cmd)
      unless status.success?
        detail = err.strip.empty? ? out.strip : err.strip
        raise Error, "command failed: #{cmd.join(' ')}\n#{detail}"
      end

      out
    end
  end
end
