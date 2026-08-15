# Tallmadge (`clpr`)

A unified CLI manager for `~/.agents/` extensions and cross-harness compatibility across AI coding assistants (such as [omp](https://github.com/coder/omp) and [pi](https://github.com/mario/pi)).

---

## Background & Inspiration

**Major Benjamin Tallmadge** (1754–1835) was the Continental Army spymaster who organized and handled the **Culper Spy Ring** for General George Washington during the American Revolutionary War.

Operating under the alias *John Bolton*, Tallmadge coordinated a clandestine network of field operatives across British-occupied New York, creating numerical ciphers, invisible ink protocols, and secure dead-drop chains.

Just as Tallmadge directed and equipped his agents in the field, **Tallmadge** (`clpr`) organizes, coordinates, and bridges AI coding agents, skills, tasks, and MCP servers on your local machine.

---

## Installation

### Via Homebrew Tap (Recommended)

```bash
brew tap kplawver/tap
brew install tallmadge
```

### Via RubyGems / Bundler

```bash
gem install tallmadge
```

Or add to your `Gemfile`:

```ruby
gem "tallmadge"
```

---

## Quick Start

Initialize directory skeletons:
```bash
clpr init
```

Install an agent or skill plugin:
```bash
# From git repository
clpr install owner/repo

# From a local directory
clpr install ./path/to/plugin

# From .agents Hub
clpr hub install bundle-id
```

Activate installed components into `~/.agents/`:
```bash
clpr activate plugin-id
```

Bridge gaps to installed AI coding harnesses:
```bash
clpr link
```

Check system status and unmanaged links:
```bash
clpr doctor
```

---

## License

MIT
