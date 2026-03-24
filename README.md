# NemoClaw Installer (safe)

A safe installer for NemoClaw that confines all artifacts under `~/.nemoclaw`, minimizing impact on the host system.

## Changes from Upstream

| Feature | Upstream | Safe variant |
|---------|----------|--------------|
| nvm auto-install | Yes | Removed -- Node.js must already be on PATH |
| Ollama auto-install | Yes | Removed |
| `npm link` (global) | Yes | Removed -- replaced with local `--prefix` install |
| `--uninstall` | No | Added |
| `--dry-run` | No | Added |
| `--upgrade` / `--rollback` / `--prune` | No | Added |
| Trap-based cleanup on error | No | Added |
| Git clone commit hash recording | No | Added |
| Versioned directory layout with symlinks | No | Added |

## Prerequisites

- Node.js >= 20 (recommended: 22)
- npm >= 10
- git
- bash (with `set -Eeuo pipefail` support)

## Directory Layout

```
~/.nemoclaw/
  source            -> source-v0.2.0  (symlink)
  prefix            -> prefix-v0.2.0  (symlink)
  source-v0.1.0/                      (previous version source)
  prefix-v0.1.0/                      (previous version prefix)
  source-v0.2.0/                      (current version source)
  prefix-v0.2.0/                      (current version prefix)
    bin/
      nemoclaw                        (CLI entry point)
  sandboxes.json                      (sandbox registry)
  .active-version                     (current active version tag)
  .version-history                    (rollback history stack, max 3 entries)
  .install.lock                       (concurrent execution lock)
```

The base directory can be changed via the `NEMOCLAW_HOME` environment variable (default: `~/.nemoclaw`).

## Usage

### Fresh Install

```bash
bash nemoclaw-install-safe.sh
```

Steps performed:

1. Verify Node.js / npm versions
2. Clone source from GitHub into a versioned directory
3. Install dependencies (`npm install --ignore-scripts`)
4. Build the NemoClaw plugin
5. Install the CLI to a versioned local prefix (`npm install --global --prefix`)
6. Activate the version via symlinks
7. Run `nemoclaw onboard`

If a NemoClaw `package.json` exists in the same directory as the installer, it installs from local source instead of cloning from GitHub.

### Upgrade

```bash
bash nemoclaw-install-safe.sh --upgrade
```

Fetches the latest release tag from the GitHub Releases API, installs the new version, and switches the active symlinks. The previous version is preserved in the history stack.

### Rollback

```bash
bash nemoclaw-install-safe.sh --rollback
```

Reverts to the previous version using the history stack (`.version-history`).

### Prune

```bash
bash nemoclaw-install-safe.sh --prune
```

Removes all installed versions older than the currently active one (semver comparison only).

### Uninstall

```bash
bash nemoclaw-install-safe.sh --uninstall
```

Removes the entire `~/.nemoclaw` directory. Any PATH entries added to shell profiles must be removed manually.

### Dry Run

```bash
bash nemoclaw-install-safe.sh --dry-run
```

Previews what actions would be taken without making any changes. Can be combined with other flags.

## Options

| Option | Description |
|--------|-------------|
| `--non-interactive` | Skip prompts (use env vars / defaults) |
| `--dry-run` | Preview actions without making changes |
| `--upgrade` | Upgrade to the latest stable release |
| `--rollback` | Roll back to the previous version |
| `--prune` | Remove versions older than the active one |
| `--uninstall` | Remove NemoClaw and all its artifacts |
| `--version`, `-v` | Print installer version and exit |
| `--help`, `-h` | Show help message and exit |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `NVIDIA_API_KEY` | API key (skips credential prompt) |
| `NEMOCLAW_HOME` | Base directory (default: `~/.nemoclaw`) |
| `NEMOCLAW_GIT_REF` | Git tag/branch to clone (default: HEAD) |
| `NEMOCLAW_NON_INTERACTIVE=1` | Same as `--non-interactive` |
| `NEMOCLAW_SANDBOX_NAME` | Sandbox name to create/use |
| `NEMOCLAW_RECREATE_SANDBOX=1` | Recreate an existing sandbox |
| `NEMOCLAW_PROVIDER` | `cloud` / `ollama` / `nim` / `vllm` |
| `NEMOCLAW_MODEL` | Inference model to configure |
| `NEMOCLAW_POLICY_MODE` | `suggested` / `custom` / `skip` |
| `NEMOCLAW_POLICY_PRESETS` | Comma-separated policy presets |
| `NEMOCLAW_EXPERIMENTAL=1` | Show experimental/local options |
| `CHAT_UI_URL` | Chat UI URL to open after setup |
| `DISCORD_BOT_TOKEN` | Auto-enable Discord policy support |
| `SLACK_BOT_TOKEN` | Auto-enable Slack policy support |
| `TELEGRAM_BOT_TOKEN` | Auto-enable Telegram policy support |

## Safety Design

- Lockfile: `.install.lock` prevents concurrent installs. Stale locks from dead processes are automatically removed.
- Trap cleanup: On install failure, partial directories are automatically removed and backups are restored.
- Backup/restore: Existing version directories are backed up before overwriting.
- Atomic symlinks: Version switching uses `mv -T` (atomic `rename(2)` on Linux) with `ln -sfn` fallback.
- Tarball validation: Pre-extraction of the openclaw package checks SHA-256 checksums, path traversal entries, symbolic links, and executable files.
- Version string validation: Only `[a-zA-Z0-9._+-]` is allowed. `..` and slashes are rejected.
- NEMOCLAW_HOME validation: System directories (`/`, `/usr`, `/etc`, etc.) are rejected.
- Source hijack prevention: A `package.json` in CWD is only used if CWD matches the installer directory.
