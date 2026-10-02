---
name: bump-version-per-pr
description: Use when preparing, committing, or shipping any PR in tallmadge; every PR must bump at least the patch version.
---

# Bump the version on every PR

Every PR to tallmadge MUST raise the version by at least a patch.

**Exception:** changes that don't touch the Ruby gem — e.g. `site/` (the tallmadge.dev website) or `.agents/` skills — do not need a bump. The gem version tracks the Ruby CLI, not the website or skill text.

## Choose the bump

- If the user named the bump (patch, minor, major, or an exact version), use it.
- If not, ASK which one before committing. Suggest patch for fixes/chores, minor for new commands or features, major for breaking changes.
- Never ship a PR without a bump. If the branch already bumped past `main`'s version, keep it.

## Where the version lives

1. `lib/tallmadge/version.rb` (`VERSION`)
2. `Gemfile.lock` (`tallmadge (X.Y.Z)`, appears twice) — regenerate with `bundle install` or `bundle lock --local`; never hand-edit.

## Steps

1. Edit `VERSION` in `lib/tallmadge/version.rb`.
2. Run `bundle lock --local` and confirm `Gemfile.lock` shows the new version.
3. Run the test suite.
4. Mention the new version in the PR body.
