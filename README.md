# Tallmadge (`clpr`)

**Tallmadge** (`clpr`) is a package manager and environment switcher for agent harnesses, skills, plugins, and marketplaces structured around the standard `~/.agents/` directory.

---

## Why "Tallmadge" & `clpr`?

Named after **Major Benjamin Tallmadge**, the spymaster who organized George Washington's **Culper Spy Ring** during the American Revolutionary War. Just as Tallmadge managed a distributed network of agents operating under aliases and codes across different stations, this tool organizes, bridges, and coordinates agent plugins, skills, tasks, and MCP servers across AI agent harnesses.

The CLI binary is named **`clpr`** (*Culper*).

---

## What It Does

1. **Global Plugin Store (`~/.tallmadge/store`)**: Installs plugins from local directories, git repositories, GitHub shorthand (`owner/repo`), marketplace catalogs (`plugin@marketplace`), or `.agents` Hub bundles.
2. **Selective Activation (`~/.agents`)**: Symlinks active skills, agents, tasks, and memory files into standard `~/.agents/` subdirectories (`skills/`, `agents/`, `tasks/`, `memories/`).
3. **Composed Files (`AGENTS.md` & `mcp.json`)**: Merges multiple plugin instructions and MCP server definitions alongside user-defined content without conflict.
4. **Harness Bridging**: Bridges gaps for harnesses like `omp` and `pi` that read subsets of `~/.agents` or use proprietary configuration paths (`~/.omp/`, `~/.pi/`).
5. **Switchable Profiles**: Create named profiles (e.g., `work`, `personal`) to instantly switch active plugins, marketplaces, adopted `AGENTS.md` fragments, and MCP servers without reinstalling.

---

## Installation

### Via Homebrew (Recommended)

```bash
brew tap kplawver/tap
brew trust kplawver/tap
brew install tallmadge
```

### Manual Installation

#### Prerequisites
- Ruby 3.2+
- Bundler

#### Setup
```bash
git clone https://github.com/kplawver/tallmadge.git
cd tallmadge
bundle install
```

You can link `bin/clpr` to your `$PATH` or run `./bin/clpr`.

Run onboarding and setup:

```bash
clpr setup
# or initialize with onboarding
clpr init --onboard
```

This safely checks if you already have an existing `~/.agents` directory, creates a timestamped backup in `~/.tallmadge/backups/`, imports custom components as standalone plugins, scans and imports external MCP server configurations (from Claude, Cursor, Cline/Roo, Oh My Pi) and marketplaces, with deduplication across all sources.

To remove Tallmadge management and restore your original `~/.agents` backup:

```bash
clpr restore
# or restore from a specific backup
clpr restore --from ~/.tallmadge/backups/YYYYMMDDTHHMMSSZ-agents-backup
```
---

## Command Reference

### Plugin Management

- **`clpr install <spec>`**: Install a plugin from a local path, git URL, GitHub repo (`owner/repo`), marketplace (`plugin@marketplace`), or Hub bundle.
  ```bash
  clpr install ./path/to/my-plugin
  clpr install https://github.com/user/agent-plugin.git
  clpr install user/agent-plugin --as my-alias
  ```
- **`clpr activate <id>`**: Symlink a plugin's components into `~/.agents/` and compose `AGENTS.md` / `mcp.json`.
  - Filter by component: `--skill <name>`, `--agent <name>`, `--task <name>`, `--memory <name>`.
  - Force override conflicts: `--force`.
  ```bash
  clpr activate my-plugin
  clpr activate my-plugin --skill lint
  ```
- **`clpr deactivate <id>`**: Remove component symlinks and recompose files.
  ```bash
  clpr deactivate my-plugin
  ```
- **`clpr list`**: List installed plugins, installation metadata, and component activation status in the current profile.
- **`clpr uninstall <id>`**: Deactivate and permanently remove a plugin from the store.
- **`clpr update [id]`**: Check installed plugins for upstream updates (use `--apply` to update).

---

### Profile Management (`clpr profile`)

Profiles manage switchable subsets of installed plugins, marketplaces, and user configurations.

- **`clpr profile list`**: List all profiles with plugin and active component counts.
- **`clpr profile current`**: Print the name of the currently active profile.
- **`clpr profile create <name>`**: Create a new empty profile.
  ```bash
  clpr profile create work
  ```
- **`clpr profile activate <name>`** (aliases: `switch`, `use`): Switch to another profile, automatically tearing down old symlinks/composed files and rebuilding the new profile's active links.
  ```bash
  clpr profile switch work
  ```
- **`clpr profile remove <name>`**: Delete a profile (cannot remove the active profile).

---

### Marketplace Management (`clpr marketplace`)

- **`clpr marketplace add <source>`**: Add a catalog from GitHub (`owner/repo`), git repository, local path, or URL.
  ```bash
  clpr marketplace add owner/marketplace-repo
  clpr marketplace add /path/to/local/marketplace
  ```
- **`clpr marketplace list`**: List added marketplaces included in the active profile.
- **`clpr marketplace update [name]`**: Refresh marketplace catalogs.
- **`clpr marketplace remove <name>`**: Remove a marketplace from the profile.

---

### Single Skill Management (`clpr skill`)

- **`clpr skill activate <name>`**: Locate the owner plugin and activate a single skill by name.
- **`clpr skill deactivate <name>`**: Deactivate a specific skill by name.
- **`clpr skills`**: View a global table of all installed skills across all plugins and their active status.

---

### Hub Bundles (`clpr hub`)

- **`clpr hub list`**: Browse community bundles from the `.agents` Hub.
- **`clpr hub install <bundle_id>`**: Download and install a bundle into the store.
- **`clpr hub update`**: Refresh catalog and check for bundle updates.

---

### Harness Gap Bridging (`clpr link` & `clpr doctor`)

- **`clpr link [harness]`**: Bridge gap links for installed harnesses (`omp`, `pi`).
- **`clpr unlink <harness>`**: Remove bridge links for a harness.
- **`clpr doctor`**: Audit symlinks, composed files, and harness configurations for issues.

---

## Testing

Run the full test suite with:

```bash
bundle exec rake test
```
