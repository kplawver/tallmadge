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
4. **Harness Bridging**: Bridges the gaps for twelve coding harnesses (Cline, Kilo Code, Amp, Devin, Claude Code, Codex, opencode, Gemini CLI, Cursor, Copilot CLI, `omp`, `pi`) that read only part of `~/.agents` or keep their own configuration elsewhere (`~/.claude/`, `~/.config/kilo/`, `~/.cline/`, …). See [Harness Support](#harness-support).
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

This safely checks if you already have an existing `~/.agents` directory, creates a timestamped backup in `~/.tallmadge/backups/`, imports custom components as plugins — grouping skills that came from the same source (symlinked from one checkout) or that share a name family (`caveman`, `caveman-commit`, … → one `caveman` plugin) into a single plugin — scans and imports external MCP server configurations (Claude, Cursor, Cline, Roo, Devin, GitHub Copilot, Gemini CLI, Amp, Oh My Pi) and marketplaces, with deduplication across all sources.

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
- **`clpr activate <id> ...`**: Symlink plugins' components into `~/.agents/` and compose `AGENTS.md` / `mcp.json`. Accepts multiple ids.
  - Filter by component: `--skill <name>`, `--agent <name>`, `--task <name>`, `--memory <name>`, `--mcp <name>` (applies to every id given).
  - Force override conflicts: `--force`.
  ```bash
  clpr activate my-plugin
  clpr activate my-plugin --skill lint
  clpr activate caveman caveman-hub ponytail
  ```
- **`clpr deactivate <id> ...`**: Remove component symlinks and recompose files. Accepts multiple ids.
  ```bash
  clpr deactivate my-plugin
  clpr deactivate caveman ponytail
  ```
- **`clpr list`**: List installed plugins, installation metadata, and component activation status in the current profile.
- **`clpr uninstall <id> ...`**: Deactivate and permanently remove plugins from the store. Accepts multiple ids.
- **`clpr update [id]`**: Check installed plugins for upstream updates (use `--apply` to update).

### User Content Files

- **`clpr edit FILE`**: Open your user copy of a composed file (`agents.md` or `mcp.json`) in the OS default application for it; creates the file and registers it in the current profile if it doesn't exist.
  ```bash
  clpr edit agents.md   # create/open your instructions fragment
  clpr edit mcp.json    # create/open your personal MCP servers
  ```
  Saved changes flow into the composed `~/.agents/agents.md` / `mcp.json` on the next rebuild (any `activate`, `deactivate`, or profile switch).

### MCP Server Management (`clpr mcp`)

- **`clpr mcp list`**: Table of every MCP server — your user servers plus each installed plugin's — with origin, type, and active status.
- **`clpr mcp get <name>`**: Show one server's config, origin, and status.
- **`clpr mcp add <name> ...`**: Add a server to your user mcp.json and recompose:
  ```bash
  clpr mcp add github --env GITHUB_TOKEN=abc -- npx -y @modelcontextprotocol/server-github
  clpr mcp add remote --url https://example.com/mcp
  clpr mcp add events --transport sse --url https://example.com/sse
  clpr mcp add custom --config '{"type":"http","url":"https://example.com/mcp","headers":{"X-Key":"v"}}'
  ```
- **`clpr mcp remove <name>`**: Remove a server from your user config.
- **`clpr mcp activate <name>` / `clpr mcp deactivate <name>`**: Enable or disable a user server, or activate/deactivate a plugin-provided one by name.

User servers live in the active profile's `mcp.json`; plugin servers can also be toggled per-server via `clpr activate <plugin> --mcp <name>`. `clpr edit mcp.json` still opens the raw user file.

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

- **`clpr link [harness]`**: Bridge gap links for every detected harness, or just the one you name.
- **`clpr unlink <harness>`**: Remove bridge links for a harness. Links a *different* linked harness still needs (such as the shared `AGENTS.md` alias) are left in place.
- **`clpr doctor`**: Audit symlinks, composed files, and harness configurations for issues, and print what each detected harness reads natively versus what clpr bridges.

`clpr refresh` notices harnesses installed since the last run and offers to bridge them; it asks first, because linking writes into each harness's own config directory. Answer no (or run `clpr link HARNESS` later) to keep them untouched.

Bridges are plain symlinks and are maintained automatically: every `activate`, `deactivate`, and profile switch re-syncs them, so a harness only ever sees the components active in the current profile.

---

### Repo Bridging (`clpr repo check` & `clpr repo link`)

For a git repository that keeps its standards in the canonical layout — a real `AGENTS.md` at the root, skills in `.agents/skills/`, subagents in `.agents/agents/` — these commands make that content work for every coding agent your teammates use:

- **`clpr repo check [DIR]`**: audit the repo's agent files and bridge links (invalid frontmatter, missing instruction aliases, broken or conflicting bridges) and report what each detected harness reads natively versus what can be bridged. Exits 1 on errors, so it works as a CI gate.
- **`clpr repo link [DIR]`**: bridge the canonical layout into each harness's repo-level config directory (`CLAUDE.md → AGENTS.md`, `.claude/skills → ../.agents/skills`, and so on). Dry run by default; pass `--execute` to create the links, `--harness ID` to bridge exactly one harness (creating its config dir if absent).

By default both commands cover the harnesses already detected in the repo. Existing files are never deleted or overwritten — a target that exists but isn't the expected link is reported as a conflict to consolidate manually. Links are relative and committable (git mode 120000), so the whole team inherits them on clone.

Repo-level bridging covers claude, cursor, cline, gemini, kilo, opencode, copilot, and omp; devin and pi read `.agents/` natively at repo scope too. Codex (TOML agents), Amp (TypeScript plugin agents), and Cline agents (YAML) are format-locked and reported as maintain-manually instead.

---

## Harness Support

At repo scope, `clpr repo link` applies the same idea to a project's own `.agents/` layout (see [Repo Bridging](#repo-bridging-clpr-repo-check--clpr-repo-link) above).

`~/.agents/skills/` has effectively won: every harness below except Claude Code loads skills straight out of it, so clpr does not touch their skill directories. Global instructions, subagents, and MCP are where the fragmentation still lives, and that is what `clpr link` bridges.

| Harness | id | Reads from `~/.agents` natively | Bridged by `clpr link` | Not bridgeable |
| --- | --- | --- | --- | --- |
| Oh My Pi | `omp` | `agents.md`, `skills/` | subagents → `~/.omp/agent/agents/<name>.md` | tasks, memories, mcp.json (not read by omp) |
| Pi | `pi` | `skills/` | `~/.pi/agent/AGENTS.md` | no subagent slot; mcp.json not read |
| Cline | `cline` | `AGENTS.md`, `skills/` | `~/.cline/data/settings/cline_mcp_settings.json` | subagents (YAML `~/.cline/agents/<name>.yml`) |
| Kilo Code | `kilo` | `skills/` | `~/.config/kilo/AGENTS.md`, `~/.config/kilo/agent/<name>.md` | MCP (`mcp` key inside `kilo.jsonc`) |
| Amp | `amp` | `skills/` | `~/.config/amp/AGENTS.md` | subagents (TypeScript plugins), MCP (`amp.mcpServers` in `settings.json`) |
| Devin CLI | `devin` | `skills/` | `~/.config/devin/AGENTS.md`, `agents/<name>/`, `mcp_config.json` | — (cloud Devin reads repo files only) |
| Claude Code | `claude` | — | `~/.claude/CLAUDE.md`, `skills/<name>`, `agents/<name>.md` | MCP (`~/.claude.json` also holds app state) |
| Codex CLI | `codex` | `skills/` | `~/.codex/AGENTS.md` | subagents and MCP (TOML in `~/.codex`) |
| opencode | `opencode` | `skills/` | `~/.config/opencode/AGENTS.md`, `agent/<name>.md` | MCP (`mcp` key inside `opencode.json`) |
| Gemini CLI | `gemini` | `skills/` | `~/.gemini/GEMINI.md`, `agents/<name>.md` | MCP (`mcpServers` in `settings.json`) |
| Cursor CLI | `cursor` | `skills/` | `~/.cursor/mcp.json`, `agents/<name>.md` | global instructions (Cursor's User Rules live in its settings UI, not a file) |
| GitHub Copilot CLI | `copilot` | `skills/` | `~/.copilot/copilot-instructions.md`, `agents/<name>.agent.md`, `mcp-config.json` | — |

Notes:

- **Filename casing.** Harnesses that read `~/.agents/AGENTS.md` (Cline, `omp`) stat that exact name, while clpr composes lowercase `agents.md`. On a case-sensitive filesystem `clpr link` adds an `AGENTS.md` → `agents.md` symlink; on macOS's case-insensitive default it is unnecessary and is skipped.
- **MCP is only bridged where a harness reads a dedicated `{"mcpServers": {…}}` file.** Where servers live inside a larger config (Amp, Kilo, opencode, Gemini, Codex) or a file that also stores app state (Claude Code), a symlink would clobber unrelated settings, so clpr leaves it alone and says so in `clpr doctor`.
- **A bridged MCP file is clpr's to own.** `cline mcp add` and `devin mcp add -s user` write into the very file clpr linked, so servers added that way are replaced on the next compose. Add them with `clpr mcp add` instead and every harness gets them.
- **Relocated homes are honored**: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `CLINE_DIR`, `COPILOT_HOME`, `CURSOR_CONFIG_DIR`, and `XDG_CONFIG_HOME` (Amp, Devin, Kilo, opencode).
- **Cloud-only agents have nothing to bridge.** Devin's web app, Jules, and the GitHub Copilot coding agent read `AGENTS.md` from the repository, not from your home directory; commit one to your project instead. The `devin` adapter targets the local Devin CLI.
- Paths above were verified against each harness's documentation or source in September 2026.

---

## Testing

Run the full test suite with:

```bash
bundle exec rake test
```
