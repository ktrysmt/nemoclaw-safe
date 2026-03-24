#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NemoClaw installer (safe) -- minimized dependency/environment impact.
#
# Design principles:
#   - All files are confined to ~/.nemoclaw (source, prefix, bin, config)
#   - No global npm link -- local prefix only
#   - trap-based cleanup on failure
#   - Versioned installs: source-<ver>/ prefix-<ver>/ with symlinks
#   - --upgrade / --rollback / --prune for lifecycle management
#   - --uninstall support for clean removal
#   - --dry-run to preview actions without side effects
#
# Changes from upstream:
#   1. REMOVED: nvm auto-install (Node.js must already be on PATH)
#   2. REMOVED: Ollama auto-install
#   3. REMOVED: npm link (replaced with local --prefix install)
#   4. ADDED:   --uninstall, --dry-run flags
#   5. ADDED:   --upgrade, --rollback, --prune flags
#   6. ADDED:   trap cleanup on error
#   7. ADDED:   git clone commit hash recording
#   8. ADDED:   versioned directory layout with symlinks

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEFAULT_NEMOCLAW_VERSION="0.1.0"

# All NemoClaw artifacts live under this single directory.
NEMOCLAW_HOME="${NEMOCLAW_HOME:-${HOME}/.nemoclaw}"
NEMOCLAW_SOURCE="${NEMOCLAW_HOME}/source"
NEMOCLAW_PREFIX="${NEMOCLAW_HOME}/prefix"
NEMOCLAW_BIN="${NEMOCLAW_PREFIX}/bin"

# Version tracking
NEMOCLAW_ACTIVE_FILE="${NEMOCLAW_HOME}/.active-version"
NEMOCLAW_HISTORY_FILE="${NEMOCLAW_HOME}/.version-history"
NEMOCLAW_HISTORY_MAX=3

# Flags
DRY_RUN=""
NON_INTERACTIVE=""

# Track partial install for cleanup
_INSTALL_STARTED=""
_INSTALL_START=""
_INSTALL_VERSION=""
_BACKUP_DIR=""
_EXIT_CODE=0

resolve_installer_version() {
  local package_json="${SCRIPT_DIR}/package.json"
  local version=""
  if [[ -f "$package_json" ]]; then
    version="$(sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([^"]+)".*/\1/p' "$package_json" | head -1)"
  fi
  printf "%s" "${version:-$DEFAULT_NEMOCLAW_VERSION}"
}

NEMOCLAW_VERSION="$(resolve_installer_version)"

# ---------------------------------------------------------------------------
# Color / style
# ---------------------------------------------------------------------------
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
  if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
    C_GREEN=$'\033[38;2;118;185;0m'
  else
    C_GREEN=$'\033[38;5;148m'
  fi
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[1;31m'
  C_YELLOW=$'\033[1;33m'
  C_CYAN=$'\033[1;36m'
  C_RESET=$'\033[0m'
else
  C_GREEN='' C_BOLD='' C_DIM='' C_RED='' C_YELLOW='' C_CYAN='' C_RESET=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "${C_CYAN}[INFO]${C_RESET}  %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*"; }
error() {
  printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2
  _EXIT_CODE=1
  exit 1
}
ok()    { printf "  ${C_GREEN}*${C_RESET}  %s\n" "$*"; }
dry()   { printf "  ${C_DIM}[dry-run]${C_RESET} %s\n" "$*"; }

step() {
  local n=$1 total=$2 msg=$3
  printf "\n${C_GREEN}[%s/%s]${C_RESET} ${C_BOLD}%s${C_RESET}\n" \
    "$n" "$total" "$msg"
  printf "  ${C_DIM}------------------------------------------------------${C_RESET}\n"
}

command_exists() { command -v "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# Version string validation
# ---------------------------------------------------------------------------
validate_version_string() {
  local v="$1"
  if [[ -z "$v" ]]; then
    error "Empty version string."
  fi
  if [[ "$v" == *..* ]]; then
    error "Version string contains '..': '${v}'"
  fi
  if [[ ! "$v" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]]; then
    error "Invalid version string: '${v}' -- must match [a-zA-Z0-9._+-]"
  fi
}

is_semver_like() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]
}

# ---------------------------------------------------------------------------
# Atomic symlink helper
# ---------------------------------------------------------------------------
_atomic_symlink() {
  local target="$1" link_path="$2"
  local tmp_link="${link_path}.tmp.$$"
  rm -f "$tmp_link"
  ln -s "$target" "$tmp_link"
  # mv -T is atomic (rename(2)) on Linux; fall back to ln -sfn elsewhere
  if mv -T "$tmp_link" "$link_path" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp_link"
  ln -sfn "$target" "$link_path"
}

# ---------------------------------------------------------------------------
# Version management
# ---------------------------------------------------------------------------
get_active_version() {
  [[ -f "$NEMOCLAW_ACTIVE_FILE" ]] && tr -d '[:space:]' < "$NEMOCLAW_ACTIVE_FILE" || true
}

# Return the most recent entry from the version history stack
get_previous_version() {
  [[ -f "$NEMOCLAW_HISTORY_FILE" ]] && head -1 "$NEMOCLAW_HISTORY_FILE" | tr -d '[:space:]' || true
}

# Push a version onto the history stack (max NEMOCLAW_HISTORY_MAX entries)
push_version_history() {
  local version="$1"
  [[ -z "$version" ]] && return 0
  local tmp="${NEMOCLAW_HISTORY_FILE}.tmp.$$"
  if [[ -f "$NEMOCLAW_HISTORY_FILE" ]]; then
    # Remove duplicates then prepend
    { printf '%s\n' "$version"
      grep -vxF "$version" "$NEMOCLAW_HISTORY_FILE" || true
    } | head -n "$NEMOCLAW_HISTORY_MAX" > "$tmp"
  else
    printf '%s\n' "$version" > "$tmp"
  fi
  mv -f "$tmp" "$NEMOCLAW_HISTORY_FILE"
}

# Pop the most recent entry from the history stack
pop_version_history() {
  if [[ -f "$NEMOCLAW_HISTORY_FILE" ]]; then
    local tmp="${NEMOCLAW_HISTORY_FILE}.tmp.$$"
    tail -n +2 "$NEMOCLAW_HISTORY_FILE" > "$tmp"
    if [[ -s "$tmp" ]]; then
      mv -f "$tmp" "$NEMOCLAW_HISTORY_FILE"
    else
      rm -f "$tmp" "$NEMOCLAW_HISTORY_FILE"
    fi
  fi
}

# Remove a specific version from the history stack
remove_from_version_history() {
  local version="$1"
  if [[ -f "$NEMOCLAW_HISTORY_FILE" ]]; then
    local tmp="${NEMOCLAW_HISTORY_FILE}.tmp.$$"
    grep -vxF "$version" "$NEMOCLAW_HISTORY_FILE" > "$tmp" || true
    if [[ -s "$tmp" ]]; then
      mv -f "$tmp" "$NEMOCLAW_HISTORY_FILE"
    else
      rm -f "$tmp" "$NEMOCLAW_HISTORY_FILE"
    fi
  fi
}

versioned_source() {
  # Defense-in-depth: reject obviously dangerous strings even if caller forgot to validate
  [[ "$1" == */* || "$1" == *..* ]] && error "Unsafe version string in versioned_source: '$1'"
  printf '%s/source-%s' "$NEMOCLAW_HOME" "$1"
}
versioned_prefix() {
  [[ "$1" == */* || "$1" == *..* ]] && error "Unsafe version string in versioned_prefix: '$1'"
  printf '%s/prefix-%s' "$NEMOCLAW_HOME" "$1"
}

# List all installed version tags (sorted by version, newest first)
list_installed_versions() {
  local v
  for d in "${NEMOCLAW_HOME}"/source-*/; do
    [[ -d "$d" ]] || continue
    v="${d%/}"
    v="${v##*/source-}"
    printf '%s\n' "$v"
  done | (sort -rV 2>/dev/null || sort -r)
}

# Resolve version string from a source directory's package.json
resolve_source_version() {
  local src_dir="$1"
  if command_exists node && [[ -f "${src_dir}/package.json" ]]; then
    local v
    v="$(node -e '
      const p=require(require("path").join(process.argv[1],"package.json"));
      const v=p.version||"";
      if(/^v?\d+\.\d+\.\d+/.test(v)){process.stdout.write(v)}
    ' "$src_dir" 2>/dev/null || true)"
    if [[ -n "$v" ]]; then
      [[ "$v" == v* ]] || v="v${v}"
      printf '%s' "$v"
    fi
  fi
}

# Activate a version: update symlinks and .active-version file.
# Callers are responsible for managing the version history stack.
activate_version() {
  local new_version="$1"
  validate_version_string "$new_version"

  local src_versioned pfx_versioned
  src_versioned="$(versioned_source "$new_version")"
  pfx_versioned="$(versioned_prefix "$new_version")"

  # Accept both real directories and symlinks whose target exists
  if [[ ! -d "$src_versioned" && ! ( -L "$src_versioned" && -d "$(readlink -f "$src_versioned")" ) ]]; then
    error "Source directory not found: $src_versioned"
  fi
  [[ -d "$pfx_versioned" ]] || error "Prefix directory not found: $pfx_versioned"

  # Atomic symlink update (relative targets so the tree is relocatable)
  _atomic_symlink "source-${new_version}" "${NEMOCLAW_HOME}/source"
  _atomic_symlink "prefix-${new_version}" "${NEMOCLAW_HOME}/prefix"

  printf '%s\n' "$new_version" > "$NEMOCLAW_ACTIVE_FILE"
  ok "Active version: ${new_version}"
}

# Fetch latest stable release tag from GitHub
fetch_latest_release_tag() {
  local tag=""
  local api_url="https://api.github.com/repos/NVIDIA/NemoClaw/releases/latest"

  # Try GitHub Releases API (curl + node for JSON parsing, with semver validation)
  if command_exists curl && command_exists node; then
    tag="$(curl -fsSL --max-time 10 "$api_url" 2>/dev/null | node -e '
      let d="";process.stdin.on("data",c=>d+=c);
      process.stdin.on("end",()=>{
        try{
          const t=JSON.parse(d).tag_name||"";
          if(/^v?\d+\.\d+\.\d+/.test(t)){process.stdout.write(t)}
        }catch{}
      })
    ' 2>/dev/null || true)"
  fi

  # Fallback: git ls-remote tags (pick latest semver tag)
  if [[ -z "$tag" ]]; then
    tag="$(git ls-remote --tags --sort=-v:refname https://github.com/NVIDIA/NemoClaw.git 2>/dev/null \
      | sed -nE 's|.*refs/tags/(v[0-9]+\.[0-9]+\.[0-9]+)$|\1|p' \
      | head -1 || true)"
  fi

  if [[ -z "$tag" ]]; then
    error "Could not determine latest release tag. Check network connectivity."
  fi

  validate_version_string "$tag"
  printf '%s' "$tag"
}

# Migrate legacy (non-versioned) layout to versioned layout
migrate_legacy_layout() {
  # Migrate .previous-version -> .version-history (one-time)
  local legacy_prev="${NEMOCLAW_HOME}/.previous-version"
  if [[ -f "$legacy_prev" && ! -f "$NEMOCLAW_HISTORY_FILE" ]]; then
    mv "$legacy_prev" "$NEMOCLAW_HISTORY_FILE"
  elif [[ -f "$legacy_prev" && -f "$NEMOCLAW_HISTORY_FILE" ]]; then
    rm -f "$legacy_prev"
  fi

  # Skip if source is already a symlink or doesn't exist
  if [[ -L "${NEMOCLAW_HOME}/source" ]] || [[ ! -d "${NEMOCLAW_HOME}/source" ]]; then
    return 0
  fi

  if [[ -n "$DRY_RUN" ]]; then
    dry "Would migrate legacy (non-versioned) layout to versioned layout"
    return 0
  fi

  info "Detected legacy (non-versioned) layout -- migrating..."
  local legacy_version=""

  # Try git tag from recorded commit
  if [[ -f "${NEMOCLAW_HOME}/source/.install-commit" ]]; then
    local commit
    commit="$(head -1 "${NEMOCLAW_HOME}/source/.install-commit")"
    legacy_version="$(git -C "${NEMOCLAW_HOME}/source" describe --tags --exact-match "$commit" 2>/dev/null || true)"
  fi

  # Try package.json version (with semver validation)
  if [[ -z "$legacy_version" ]] && command_exists node; then
    legacy_version="$(node -e '
      const p=require(require("path").join(process.argv[1],"package.json"));
      const v=p.version||"";
      if(/^v?\d+\.\d+\.\d+/.test(v)){process.stdout.write(v.startsWith("v")?v:"v"+v)}
    ' "${NEMOCLAW_HOME}/source" 2>/dev/null || true)"
  fi

  [[ -z "$legacy_version" || "$legacy_version" == "v" ]] && legacy_version="legacy"

  validate_version_string "$legacy_version"

  mv "${NEMOCLAW_HOME}/source" "${NEMOCLAW_HOME}/source-${legacy_version}"
  if [[ -d "${NEMOCLAW_HOME}/prefix" && ! -L "${NEMOCLAW_HOME}/prefix" ]]; then
    mv "${NEMOCLAW_HOME}/prefix" "${NEMOCLAW_HOME}/prefix-${legacy_version}"
  fi
  activate_version "$legacy_version"
  ok "Migrated legacy layout to version: ${legacy_version}"
}

# Check if version $1 is older than version $2 (semver-like only)
is_version_older() {
  local v1="$1" v2="$2"
  [[ "$v1" == "$v2" ]] && return 1
  # Only compare semver-like versions; non-semver is incomparable
  is_semver_like "$v1" && is_semver_like "$v2" || return 1
  local oldest
  oldest="$(printf '%s\n%s\n' "$v1" "$v2" | (sort -V 2>/dev/null || sort) | head -1)"
  [[ "$oldest" == "$v1" ]]
}

# ---------------------------------------------------------------------------
# Validate NEMOCLAW_HOME -- refuse system directories
# ---------------------------------------------------------------------------
validate_nemoclaw_home() {
  local resolved="$NEMOCLAW_HOME"
  if [[ -d "$resolved" ]]; then
    resolved="$(cd "$resolved" && pwd -P)"
  fi
  case "$resolved" in
    /|/bin|/boot|/dev|/etc|/lib|/lib64|/opt|/proc|/run|/sbin|/sys|/usr|/var|/tmp)
      error "NEMOCLAW_HOME='${NEMOCLAW_HOME}' points to a system directory. Refusing to proceed."
      ;;
  esac
  if [[ "${#resolved}" -lt 5 ]]; then
    error "NEMOCLAW_HOME='${NEMOCLAW_HOME}' is too short and likely dangerous. Set a proper path."
  fi
}

# ---------------------------------------------------------------------------
# Spinner -- temp file leak fixed
# ---------------------------------------------------------------------------
spin() {
  local msg="$1"
  shift

  if [[ -n "$DRY_RUN" ]]; then
    dry "$msg: $*"
    return 0
  fi

  if [[ ! -t 1 ]]; then
    info "$msg"
    "$@"
    return
  fi

  local log status=0
  log=$(mktemp)

  "$@" >"$log" 2>&1 &
  local pid=$! i=0
  local frames=('.' '..' '...' '....' '.....')

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${C_GREEN}%s${C_RESET}  %s" "${frames[$((i++ % 5))]}" "$msg"
    sleep 0.15
  done

  wait "$pid" || status=$?

  if [[ $status -eq 0 ]]; then
    printf "\r  ${C_GREEN}*${C_RESET}  %s\n" "$msg"
  else
    printf "\r  ${C_RED}x${C_RESET}  %s\n\n" "$msg"
    cat "$log" >&2
    printf "\n"
  fi

  rm -f "$log"
  return $status
}

# ---------------------------------------------------------------------------
# Backup / restore for safe reinstall (versioned)
# ---------------------------------------------------------------------------
backup_existing() {
  local version="$1"
  local src pfx
  src="$(versioned_source "$version")"
  pfx="$(versioned_prefix "$version")"
  if [[ -d "$src" || -d "$pfx" ]]; then
    _BACKUP_DIR="${NEMOCLAW_HOME}/.backup-$(date +%s)-$$"
    mkdir -p "$_BACKUP_DIR"
    info "Existing v${version} detected -- backing up to $_BACKUP_DIR"
    [[ -d "$src" ]] && mv "$src" "$_BACKUP_DIR/source"
    [[ -d "$pfx" ]] && mv "$pfx" "$_BACKUP_DIR/prefix"
  fi
}

restore_from_backup() {
  local version="$1"
  if [[ -n "${_BACKUP_DIR:-}" && -d "$_BACKUP_DIR" ]]; then
    warn "Restoring previous v${version} from backup..."
    local src pfx
    src="$(versioned_source "$version")"
    pfx="$(versioned_prefix "$version")"
    if [[ -d "$_BACKUP_DIR/source" ]]; then
      rm -rf "$src"
      mv "$_BACKUP_DIR/source" "$src"
    fi
    if [[ -d "$_BACKUP_DIR/prefix" ]]; then
      rm -rf "$pfx"
      mv "$_BACKUP_DIR/prefix" "$pfx"
    fi
    rm -rf "$_BACKUP_DIR"
    info "Previous v${version} restored."
  fi
}

remove_backup() {
  if [[ -n "${_BACKUP_DIR:-}" && -d "$_BACKUP_DIR" ]]; then
    rm -rf "$_BACKUP_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Lockfile -- prevent concurrent installs
# ---------------------------------------------------------------------------
_LOCKFILE="${NEMOCLAW_HOME}/.install.lock"

acquire_lock() {
  mkdir -p "$(dirname "$_LOCKFILE")"
  if ! (set -o noclobber; echo $$ > "$_LOCKFILE") 2>/dev/null; then
    local other_pid
    other_pid="$(cat "$_LOCKFILE" 2>/dev/null || echo "unknown")"
    # Check if the locking process is still alive
    if [[ "$other_pid" =~ ^[0-9]+$ ]] && kill -0 "$other_pid" 2>/dev/null; then
      error "Another installer is running (PID: ${other_pid}). If stale, remove ${_LOCKFILE}."
    else
      warn "Stale lock found (PID: ${other_pid} no longer running). Removing."
      rm -f "$_LOCKFILE"
      if ! (set -o noclobber; echo $$ > "$_LOCKFILE") 2>/dev/null; then
        error "Failed to acquire lock after removing stale lockfile."
      fi
    fi
  fi
}

release_lock() {
  rm -f "$_LOCKFILE"
}

# ---------------------------------------------------------------------------
# Cleanup on exit (handles both ERR and explicit error() calls)
# ---------------------------------------------------------------------------
cleanup_on_exit() {
  local ec=$?
  if [[ ${_EXIT_CODE:-0} -ne 0 || $ec -ne 0 ]] && [[ -n "${_INSTALL_STARTED:-}" ]]; then
    warn "Installation failed -- cleaning up partial install..."
    if [[ -n "${_INSTALL_VERSION:-}" ]]; then
      local src pfx
      src="$(versioned_source "$_INSTALL_VERSION")"
      pfx="$(versioned_prefix "$_INSTALL_VERSION")"
      [[ -d "$src" ]] && rm -rf "$src"
      [[ -d "$pfx" ]] && rm -rf "$pfx"
      restore_from_backup "$_INSTALL_VERSION"
    fi
    # Clean up temp clone directory
    rm -rf "${NEMOCLAW_HOME}/.clone-tmp-$$"
    warn "Fix the issue above and re-run."
  fi
  release_lock
}

trap cleanup_on_exit EXIT

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  printf "\n"
  info "=== NemoClaw Uninstall ==="
  printf "\n"

  if [[ ! -d "$NEMOCLAW_HOME" ]]; then
    info "Nothing to uninstall: $NEMOCLAW_HOME does not exist."
    exit 0
  fi

  info "The following directory will be removed:"
  printf "  %s\n" "$NEMOCLAW_HOME"

  # Show disk usage
  if command_exists du; then
    local size
    size="$(du -sh "$NEMOCLAW_HOME" 2>/dev/null | cut -f1 || echo "unknown")"
    info "Disk usage: $size"
  fi

  printf "\n"

  if [[ "$NON_INTERACTIVE" != "1" ]]; then
    printf "  Continue? [y/N] "
    read -r answer
    if [[ "$answer" != [yY] ]]; then
      info "Uninstall cancelled."
      exit 0
    fi
  fi

  if [[ -n "$DRY_RUN" ]]; then
    dry "Would remove: $NEMOCLAW_HOME"
    dry "Would remove PATH entry: $NEMOCLAW_BIN"
    exit 0
  fi

  rm -rf "$NEMOCLAW_HOME"
  ok "Removed $NEMOCLAW_HOME"

  printf "\n"
  info "Uninstall complete."
  info "If you added $NEMOCLAW_BIN to your shell profile, remove that line manually."
  printf "\n"
  exit 0
}

# ---------------------------------------------------------------------------
# Banner / Done / Usage
# ---------------------------------------------------------------------------
print_banner() {
  printf "\n"
  printf "  ${C_GREEN}${C_BOLD} NemoClaw Installer (safe)${C_RESET}  ${C_DIM}v%s${C_RESET}\n" "$NEMOCLAW_VERSION"
  printf "  ${C_DIM}All artifacts confined to %s${C_RESET}\n" "$NEMOCLAW_HOME"
  printf "\n"
}

resolve_default_sandbox_name() {
  local registry_file="${NEMOCLAW_HOME}/sandboxes.json"
  local sandbox_name="${NEMOCLAW_SANDBOX_NAME:-}"

  if [[ -z "$sandbox_name" && -f "$registry_file" ]] && command_exists node; then
    sandbox_name="$(
      node -e '
        const fs = require("fs");
        const file = process.argv[1];
        try {
          const data = JSON.parse(fs.readFileSync(file, "utf8"));
          const sandboxes = data.sandboxes || {};
          const preferred = data.defaultSandbox;
          const name = (preferred && sandboxes[preferred] && preferred) || Object.keys(sandboxes)[0] || "";
          process.stdout.write(name);
        } catch {}
      ' "$registry_file" 2>/dev/null || true
    )"
  fi

  printf "%s" "${sandbox_name:-my-assistant}"
}

print_done() {
  local elapsed=0
  if [[ -n "$_INSTALL_START" ]]; then
    elapsed=$((SECONDS - _INSTALL_START))
  fi
  local sandbox_name
  sandbox_name="$(resolve_default_sandbox_name)"
  local active_ver
  active_ver="$(get_active_version)"
  info "=== Installation complete ==="
  printf "\n"
  printf "  ${C_GREEN}${C_BOLD}NemoClaw${C_RESET}  ${C_DIM}(%ss)${C_RESET}\n" "$elapsed"
  if [[ -n "$active_ver" ]]; then
    printf "  ${C_DIM}Version: %s${C_RESET}\n" "$active_ver"
  fi
  printf "\n"
  printf "  ${C_GREEN}Your OpenClaw Sandbox is live.${C_RESET}\n"
  printf "\n"
  printf "  ${C_GREEN}Next:${C_RESET}\n"
  printf "  %s$%s nemoclaw %s connect\n" "$C_GREEN" "$C_RESET" "$sandbox_name"
  printf "  %ssandbox@%s$%s openclaw tui\n" "$C_GREEN" "$sandbox_name" "$C_RESET"
  printf "\n"
  printf "  ${C_DIM}Installed to: %s${C_RESET}\n" "$NEMOCLAW_HOME"
  printf "  ${C_DIM}Binary:       %s/nemoclaw${C_RESET}\n" "$NEMOCLAW_BIN"
  printf "\n"

  # PATH guidance -- detect user's shell profile
  if [[ ":${PATH}:" != *":${NEMOCLAW_BIN}:"* ]]; then
    local shell_profile=""
    case "${SHELL:-}" in
      */zsh)
        if [[ -f "${HOME}/.zshrc" ]]; then shell_profile="${HOME}/.zshrc"
        else shell_profile="${HOME}/.zprofile"; fi
        ;;
      */bash)
        if [[ -f "${HOME}/.bashrc" ]]; then shell_profile="${HOME}/.bashrc"
        elif [[ -f "${HOME}/.bash_profile" ]]; then shell_profile="${HOME}/.bash_profile"
        else shell_profile="${HOME}/.profile"; fi
        ;;
      *)
        shell_profile="${HOME}/.profile"
        ;;
    esac

    local path_line="export PATH=\"${NEMOCLAW_BIN}:\$PATH\""
    warn "nemoclaw is not on your PATH. Add this to ${shell_profile}:"
    printf "\n"
    printf "  %s\n" "$path_line"
    printf "\n"
    printf "  ${C_CYAN}[INFO]${C_RESET}  Or run now:  echo '%s' >> %s && source %s\n" "$path_line" "$shell_profile" "$shell_profile"
    printf "\n"
  fi

  printf "  ${C_BOLD}GitHub${C_RESET}  ${C_DIM}https://github.com/nvidia/nemoclaw${C_RESET}\n"
  printf "  ${C_BOLD}Docs${C_RESET}    ${C_DIM}https://docs.nvidia.com/nemoclaw/latest/${C_RESET}\n"
  printf "\n"
}

usage() {
  printf "\n"
  printf "  ${C_BOLD}NemoClaw Installer (safe)${C_RESET}  ${C_DIM}v%s${C_RESET}\n\n" "$NEMOCLAW_VERSION"
  printf "  ${C_DIM}Usage:${C_RESET}\n"
  printf "    bash nemoclaw-install-safe.sh [options]\n\n"
  printf "  ${C_DIM}Options:${C_RESET}\n"
  printf "    --non-interactive    Skip prompts (uses env vars / defaults)\n"
  printf "    --dry-run            Preview actions without making changes\n"
  printf "    --upgrade            Upgrade to the latest stable release\n"
  printf "    --rollback           Roll back to the previous version\n"
  printf "    --prune              Remove versions older than the active one\n"
  printf "    --uninstall          Remove NemoClaw and all its artifacts\n"
  printf "    --version, -v        Print installer version and exit\n"
  printf "    --help, -h           Show this help message and exit\n\n"
  printf "  ${C_DIM}Lifecycle:${C_RESET}\n"
  printf "    Install:   bash nemoclaw-install-safe.sh\n"
  printf "    Upgrade:   bash nemoclaw-install-safe.sh --upgrade\n"
  printf "    Rollback:  bash nemoclaw-install-safe.sh --rollback\n"
  printf "    Prune:     bash nemoclaw-install-safe.sh --prune\n\n"
  printf "  ${C_DIM}Environment:${C_RESET}\n"
  printf "    NVIDIA_API_KEY                API key (skips credential prompt)\n"
  printf "    NEMOCLAW_HOME                 Base directory (default: ~/.nemoclaw)\n"
  printf "    NEMOCLAW_GIT_REF              Git tag/branch to clone (default: HEAD)\n"
  printf "    NEMOCLAW_NON_INTERACTIVE=1    Same as --non-interactive\n"
  printf "    NEMOCLAW_SANDBOX_NAME         Sandbox name to create/use\n"
  printf "    NEMOCLAW_RECREATE_SANDBOX=1   Recreate an existing sandbox\n"
  printf "    NEMOCLAW_PROVIDER             cloud | ollama | nim | vllm\n"
  printf "    NEMOCLAW_MODEL                Inference model to configure\n"
  printf "    NEMOCLAW_POLICY_MODE          suggested | custom | skip\n"
  printf "    NEMOCLAW_POLICY_PRESETS       Comma-separated policy presets\n"
  printf "    NEMOCLAW_EXPERIMENTAL=1       Show experimental/local options\n"
  printf "    CHAT_UI_URL                   Chat UI URL to open after setup\n"
  printf "    DISCORD_BOT_TOKEN             Auto-enable Discord policy support\n"
  printf "    SLACK_BOT_TOKEN               Auto-enable Slack policy support\n"
  printf "    TELEGRAM_BOT_TOKEN            Auto-enable Telegram policy support\n"
  printf "\n"
  printf "  ${C_DIM}Getting an API key:${C_RESET}\n"
  printf "    1. Visit https://build.nvidia.com/\n"
  printf "    2. Sign in with your NVIDIA account (free to create)\n"
  printf "    3. Open any model page and click \"Get API Key\"\n"
  printf "    4. Set NVIDIA_API_KEY=nvapi-... before running this installer\n"
  printf "\n"
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------
MIN_NODE_MAJOR=20
MIN_NPM_MAJOR=10
RECOMMENDED_NODE_MAJOR=22
RUNTIME_REQUIREMENT_MSG="NemoClaw requires Node.js >=${MIN_NODE_MAJOR} and npm >=${MIN_NPM_MAJOR} (recommended Node.js ${RECOMMENDED_NODE_MAJOR})."

version_major() {
  printf '%s\n' "${1#v}" | cut -d. -f1
}

# ---------------------------------------------------------------------------
# 1. Node.js -- check only, never auto-install
# ---------------------------------------------------------------------------
check_nodejs() {
  if ! command_exists node; then
    error "Node.js is not installed. Please install Node.js >= ${MIN_NODE_MAJOR} before running this installer."
  fi
  if ! command_exists npm; then
    error "npm is not installed. Please install npm >= ${MIN_NPM_MAJOR} before running this installer."
  fi

  local node_version npm_version node_major npm_major
  node_version="$(node --version 2>/dev/null || true)"
  npm_version="$(npm --version 2>/dev/null || true)"
  node_major="$(version_major "$node_version")"
  npm_major="$(version_major "$npm_version")"

  [[ "$node_major" =~ ^[0-9]+$ ]] || error "Could not determine Node.js version from '${node_version}'. ${RUNTIME_REQUIREMENT_MSG}"
  [[ "$npm_major" =~ ^[0-9]+$ ]] || error "Could not determine npm version from '${npm_version}'. ${RUNTIME_REQUIREMENT_MSG}"

  if ((node_major < MIN_NODE_MAJOR || npm_major < MIN_NPM_MAJOR)); then
    error "Unsupported runtime: Node.js ${node_version:-unknown}, npm ${npm_version:-unknown}. ${RUNTIME_REQUIREMENT_MSG}"
  fi

  ok "Runtime OK: Node.js ${node_version}, npm ${npm_version}"
}

# ---------------------------------------------------------------------------
# 2. NemoClaw -- install to local prefix, no global npm link
# ---------------------------------------------------------------------------
pre_extract_openclaw() {
  local install_dir="$1"
  local openclaw_version
  openclaw_version=$(node -e 'const p=require(require("path").join(process.argv[1],"package.json"));console.log((p.dependencies&&p.dependencies.openclaw)||"")' "$install_dir" 2>/dev/null || echo "")

  if [[ -z "$openclaw_version" ]]; then
    warn "Could not determine openclaw version -- skipping pre-extraction"
    return 1
  fi

  # Validate version string to prevent shell injection via malicious package.json
  if [[ ! "$openclaw_version" =~ ^[a-zA-Z0-9@^~.\>\<=\ -]+$ ]]; then
    warn "Suspicious openclaw version string: '${openclaw_version}' -- skipping pre-extraction"
    return 1
  fi

  info "Pre-extracting openclaw@${openclaw_version} with system tar (GH-503 workaround)..."
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  if npm pack "openclaw@${openclaw_version}" --ignore-scripts --pack-destination "$tmpdir" >/dev/null 2>&1; then
    local tgz
    tgz="$(find "$tmpdir" -maxdepth 1 -name 'openclaw-*.tgz' -print -quit)"
    if [[ -n "$tgz" && -f "$tgz" ]]; then
      # Verify tarball integrity with SHA-256
      local sha256=""
      if command_exists sha256sum; then
        sha256="$(sha256sum "$tgz" | cut -d' ' -f1)"
      elif command_exists shasum; then
        sha256="$(shasum -a 256 "$tgz" | cut -d' ' -f1)"
      fi
      if [[ -n "$sha256" ]]; then
        info "openclaw tarball SHA-256: ${sha256}"
      else
        warn "Could not compute SHA-256 checksum (sha256sum/shasum not found)"
      fi

      # Verify tarball contains only expected file types (no scripts, binaries, etc.)
      local suspicious
      suspicious="$(tar tzf "$tgz" 2>/dev/null | grep -iE '\.(sh|exe|bat|cmd|ps1|dll|so|dylib)$' || true)"
      if [[ -n "$suspicious" ]]; then
        warn "Tarball contains unexpected executable files:"
        printf "  %s\n" "$suspicious" >&2
        warn "Aborting pre-extraction for safety."
        return 1
      fi

      # Detect path traversal entries (../)
      local traversal
      traversal="$(tar tzf "$tgz" 2>/dev/null | grep -E '(^|/)\.\.(/|$)' || true)"
      if [[ -n "$traversal" ]]; then
        warn "Tarball contains path traversal entries:"
        printf "  %s\n" "$traversal" >&2
        warn "Aborting pre-extraction for safety."
        return 1
      fi

      # Detect symlinks in tarball
      local symlinks
      symlinks="$(tar tvf "$tgz" 2>/dev/null | grep -E '^l' || true)"
      if [[ -n "$symlinks" ]]; then
        warn "Tarball contains symbolic links:"
        printf "  %s\n" "$symlinks" >&2
        warn "Aborting pre-extraction for safety."
        return 1
      fi

      if mkdir -p "${install_dir}/node_modules/openclaw" \
        && tar xzf "$tgz" -C "${install_dir}/node_modules/openclaw" --strip-components=1 --no-same-owner; then
        info "openclaw pre-extracted successfully"
      else
        warn "Failed to extract openclaw tarball"
        return 1
      fi
    else
      warn "npm pack succeeded but tarball not found"
      return 1
    fi
  else
    warn "Failed to download openclaw tarball"
    return 1
  fi

  trap - RETURN
  rm -rf "$tmpdir"
}

install_nemoclaw() {
  _INSTALL_START="${SECONDS}"
  _INSTALL_STARTED="1"

  migrate_legacy_layout

  local install_from_source=""

  if [[ -f "./package.json" ]] && grep -q '"name": "nemoclaw"' ./package.json 2>/dev/null; then
    # Verify CWD matches installer directory to prevent local hijack
    local cwd_resolved script_dir_resolved
    cwd_resolved="$(pwd -P)"
    script_dir_resolved="$(cd "$SCRIPT_DIR" && pwd -P)"
    if [[ "$cwd_resolved" == "$script_dir_resolved" ]]; then
      install_from_source="local"
      info "NemoClaw package.json found in installer directory -- installing from source..."
    else
      warn "Found nemoclaw package.json in CWD ($cwd_resolved) but installer is at $script_dir_resolved."
      warn "Ignoring local source to prevent hijacking. cd to installer directory to use local source."
      install_from_source="github"
      info "Installing NemoClaw from GitHub..."
    fi
  else
    install_from_source="github"
    info "Installing NemoClaw from GitHub..."
  fi

  if [[ -n "$DRY_RUN" ]]; then
    if [[ "$install_from_source" == "local" ]]; then
      dry "Would install from current directory to versioned prefix"
    else
      dry "Would clone https://github.com/NVIDIA/NemoClaw.git"
      dry "Would install dependencies with --ignore-scripts"
      dry "Would build nemoclaw plugin"
      dry "Would install CLI to versioned prefix (npm --prefix)"
    fi
    return 0
  fi

  local src_dir
  if [[ "$install_from_source" == "local" ]]; then
    src_dir="$(pwd -P)"
    # Determine version for local install
    if [[ -z "$_INSTALL_VERSION" ]]; then
      _INSTALL_VERSION="$(resolve_source_version "$src_dir")"
      [[ -z "$_INSTALL_VERSION" ]] && _INSTALL_VERSION="local"
    fi
    validate_version_string "$_INSTALL_VERSION"
    # Create a symlink from versioned source to local directory
    local target_src
    target_src="$(versioned_source "$_INSTALL_VERSION")"
    if [[ ! -e "$target_src" ]]; then
      ln -s "$src_dir" "$target_src"
    fi
    warn "Local install: source-${_INSTALL_VERSION} is a symlink to ${src_dir}."
    warn "If that directory is moved or deleted, this installation will break."
  else
    # Clone to temporary directory first
    local clone_tmp="${NEMOCLAW_HOME}/.clone-tmp-$$"
    rm -rf "$clone_tmp"
    mkdir -p "$(dirname "$clone_tmp")"

    local git_ref="${NEMOCLAW_GIT_REF:-}"
    if [[ -n "$git_ref" ]]; then
      spin "Cloning NemoClaw source (ref: ${git_ref})" git clone --depth 1 --branch "$git_ref" https://github.com/NVIDIA/NemoClaw.git "$clone_tmp"
    else
      spin "Cloning NemoClaw source (HEAD)" git clone --depth 1 https://github.com/NVIDIA/NemoClaw.git "$clone_tmp"
    fi

    # Record the commit hash for audit/reproducibility
    local commit_hash
    commit_hash="$(git -C "$clone_tmp" rev-parse HEAD 2>/dev/null || echo "unknown")"
    printf "%s\n" "$commit_hash" > "${clone_tmp}/.install-commit"
    info "Cloned at commit: ${commit_hash}"
    if [[ -z "$git_ref" ]]; then
      warn "No NEMOCLAW_GIT_REF set -- cloned unpinned HEAD. Consider setting NEMOCLAW_GIT_REF=v<version> for reproducibility."
    fi

    # Determine version from source
    if [[ -z "$_INSTALL_VERSION" ]]; then
      _INSTALL_VERSION="$(resolve_source_version "$clone_tmp")"
      if [[ -z "$_INSTALL_VERSION" ]]; then
        _INSTALL_VERSION="${git_ref:-HEAD-${commit_hash:0:8}}"
      fi
    fi
    validate_version_string "$_INSTALL_VERSION"

    # Move clone to versioned directory
    local target_src
    target_src="$(versioned_source "$_INSTALL_VERSION")"
    backup_existing "$_INSTALL_VERSION"
    rm -rf "$target_src"
    mv "$clone_tmp" "$target_src"
    src_dir="$target_src"
  fi

  info "Installing version: ${_INSTALL_VERSION}"

  spin "Preparing OpenClaw package" bash -c "$(declare -p C_CYAN C_YELLOW C_RED C_GREEN C_DIM C_RESET 2>/dev/null || true); $(declare -f command_exists info warn pre_extract_openclaw); pre_extract_openclaw \"\$1\"" _ "$src_dir" \
    || warn "Pre-extraction failed -- npm install may fail if openclaw tarball is broken"

  spin "Installing NemoClaw dependencies" bash -c "cd \"\$1\" && npm install --ignore-scripts" _ "$src_dir"
  spin "Building NemoClaw plugin" bash -c "cd \"\$1\"/nemoclaw && npm install --ignore-scripts && npm run build" _ "$src_dir"

  # Install to versioned prefix
  local target_pfx
  target_pfx="$(versioned_prefix "$_INSTALL_VERSION")"
  mkdir -p "$target_pfx"
  spin "Installing NemoClaw CLI to local prefix" bash -c "cd \"\$1\" && npm install --global --prefix \"\$2\" --ignore-scripts ." _ "$src_dir" "$target_pfx"

  # Fallback: if package.json has no "bin" field, npm won't create bin/nemoclaw.
  # Create a manual wrapper in that case.
  local target_bin="${target_pfx}/bin"
  if [[ ! -x "${target_bin}/nemoclaw" ]]; then
    local main_entry
    main_entry="$(node -e '
      const p = require(require("path").join(process.argv[1], "package.json"));
      const bin = p.bin;
      if (typeof bin === "string") { process.stdout.write(bin); }
      else if (bin && bin.nemoclaw) { process.stdout.write(bin.nemoclaw); }
      else if (p.main) { process.stdout.write(p.main); }
    ' "$src_dir" 2>/dev/null || true)"

    if [[ -z "$main_entry" ]]; then
      warn "No 'bin' or 'main' field found in package.json -- cannot create CLI entry point."
      warn "nemoclaw may not be executable. Check the package structure."
    elif [[ "$main_entry" == /* ]]; then
      error "Absolute entry point not allowed: '${main_entry}' -- aborting."
    elif [[ "$main_entry" =~ (^|/)\.\.(/|$) ]]; then
      error "Path traversal in entry point: '${main_entry}' -- aborting."
    elif [[ ! -f "${src_dir}/${main_entry}" ]]; then
      error "Entry point '${main_entry}' does not exist in ${src_dir}"
    else
      mkdir -p "$target_bin"
      cat > "${target_bin}/nemoclaw" <<SHIM
#!/usr/bin/env bash
exec node "${src_dir}/${main_entry}" "\$@"
SHIM
      chmod +x "${target_bin}/nemoclaw"
      info "Created manual wrapper at ${target_bin}/nemoclaw -> ${src_dir}/${main_entry}"
    fi
  fi

  # Activate this version (create/update symlinks)
  local old_active
  old_active="$(get_active_version)"
  activate_version "$_INSTALL_VERSION"
  if [[ -n "$old_active" && "$old_active" != "$_INSTALL_VERSION" ]]; then
    push_version_history "$old_active"
  fi

  # Install succeeded -- remove backup
  remove_backup
  _INSTALL_STARTED=""
}

# ---------------------------------------------------------------------------
# 3. Verify
# ---------------------------------------------------------------------------
verify_nemoclaw() {
  # Add our bin to PATH for verification
  if [[ -d "$NEMOCLAW_BIN" && ":${PATH}:" != *":${NEMOCLAW_BIN}:"* ]]; then
    export PATH="${NEMOCLAW_BIN}:${PATH}"
  fi

  if [[ -n "$DRY_RUN" ]]; then
    dry "Would verify nemoclaw binary at $NEMOCLAW_BIN/nemoclaw"
    return 0
  fi

  if [[ -x "${NEMOCLAW_BIN}/nemoclaw" ]]; then
    ok "Verified: nemoclaw is available at ${NEMOCLAW_BIN}/nemoclaw"
    return 0
  fi

  if command_exists nemoclaw; then
    ok "Verified: nemoclaw is available at $(command -v nemoclaw)"
    return 0
  fi

  error "Installation failed: nemoclaw binary not found at ${NEMOCLAW_BIN}/nemoclaw"
}

# ---------------------------------------------------------------------------
# 4. Onboard
# ---------------------------------------------------------------------------
run_onboard() {
  if [[ -n "$DRY_RUN" ]]; then
    dry "Would run: nemoclaw onboard"
    return 0
  fi

  info "Running nemoclaw onboard..."
  if [[ "$NON_INTERACTIVE" == "1" ]]; then
    nemoclaw onboard --non-interactive
  elif [[ -t 0 ]]; then
    nemoclaw onboard
  elif [[ -c /dev/tty ]] && exec 3</dev/tty; then
    info "Installer stdin is piped; attaching onboarding to /dev/tty..."
    local status=0
    nemoclaw onboard <&3 || status=$?
    exec 3<&-
    return "$status"
  else
    error "Interactive onboarding requires a TTY. Re-run in a terminal or set NEMOCLAW_NON_INTERACTIVE=1."
  fi
}

# ---------------------------------------------------------------------------
# Upgrade
# ---------------------------------------------------------------------------
do_upgrade() {
  printf "\n"
  info "=== NemoClaw Upgrade ==="
  printf "\n"

  migrate_legacy_layout

  local current_version
  current_version="$(get_active_version)"

  info "Fetching latest release tag..."
  local latest_tag
  latest_tag="$(fetch_latest_release_tag)"
  info "Latest release: ${latest_tag}"

  if [[ -n "$current_version" ]]; then
    info "Current version: ${current_version}"
  fi

  if [[ -n "$current_version" && "$current_version" == "$latest_tag" ]]; then
    ok "Already up to date: ${current_version}"
    exit 0
  fi

  # Check if this version is already installed (e.g. rolled back from it)
  local existing_src existing_pfx
  existing_src="$(versioned_source "$latest_tag")"
  existing_pfx="$(versioned_prefix "$latest_tag")"

  if [[ -d "$existing_src" && -d "$existing_pfx" ]]; then
    info "Version ${latest_tag} is already installed. Re-activating..."
    if [[ -n "$DRY_RUN" ]]; then
      dry "Would re-activate version ${latest_tag}"
      exit 0
    fi
    local old_active
    old_active="$(get_active_version)"
    activate_version "$latest_tag"
    if [[ -n "$old_active" && "$old_active" != "$latest_tag" ]]; then
      push_version_history "$old_active"
    fi
    verify_nemoclaw
    printf "\n"
    info "=== Upgrade complete: ${current_version:-none} -> ${latest_tag} (re-activated) ==="
    printf "\n"
    exit 0
  fi

  if [[ -n "$DRY_RUN" ]]; then
    dry "Would upgrade: ${current_version:-none} -> ${latest_tag}"
    dry "Would clone https://github.com/NVIDIA/NemoClaw.git (ref: ${latest_tag})"
    dry "Would build and install to versioned prefix"
    exit 0
  fi

  # Full install of new version
  _INSTALL_VERSION="$latest_tag"
  export NEMOCLAW_GIT_REF="$latest_tag"

  print_banner

  step 1 2 "Node.js"
  check_nodejs

  step 2 2 "NemoClaw CLI (${latest_tag})"
  install_nemoclaw
  verify_nemoclaw

  printf "\n"
  info "=== Upgrade complete: ${current_version:-none} -> ${latest_tag} ==="
  printf "\n"
}

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------
do_rollback() {
  printf "\n"
  info "=== NemoClaw Rollback ==="
  printf "\n"

  migrate_legacy_layout

  local current_version previous_version
  current_version="$(get_active_version)"
  previous_version="$(get_previous_version)"

  if [[ -z "$previous_version" ]]; then
    error "No previous version found. Nothing to roll back to."
  fi

  info "Current version:  ${current_version:-none}"
  info "Previous version: ${previous_version}"

  # Show remaining history
  if [[ -f "$NEMOCLAW_HISTORY_FILE" ]]; then
    local depth
    depth="$(wc -l < "$NEMOCLAW_HISTORY_FILE" | tr -d ' ')"
    info "History depth: ${depth} version(s)"
  fi

  # Verify previous version directories exist
  local prev_src prev_pfx
  prev_src="$(versioned_source "$previous_version")"
  prev_pfx="$(versioned_prefix "$previous_version")"

  if [[ ! -d "$prev_src" || ! -d "$prev_pfx" ]]; then
    error "Previous version ${previous_version} directories are missing. Cannot roll back."
  fi

  if [[ -n "$DRY_RUN" ]]; then
    dry "Would roll back: ${current_version} -> ${previous_version}"
    exit 0
  fi

  activate_version "$previous_version"
  pop_version_history

  verify_nemoclaw

  printf "\n"
  info "=== Rollback complete: ${current_version} -> ${previous_version} ==="
  info "Run --upgrade to return to ${current_version}."
  printf "\n"
}

# ---------------------------------------------------------------------------
# Prune
# ---------------------------------------------------------------------------
do_prune() {
  printf "\n"
  info "=== NemoClaw Prune ==="
  printf "\n"

  migrate_legacy_layout

  local active_version
  active_version="$(get_active_version)"

  if [[ -z "$active_version" ]]; then
    error "No active version found. Nothing to prune."
  fi

  info "Active version: ${active_version}"

  if ! is_semver_like "$active_version"; then
    warn "Active version '${active_version}' is not semver-like. Cannot determine which versions are older."
    warn "Prune only works when the active version follows semver (e.g. v1.2.3)."
    exit 1
  fi

  # Collect versions older than active (skip non-semver)
  local to_remove=()
  local skipped=()
  local v
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    [[ "$v" == "$active_version" ]] && continue
    if ! is_semver_like "$v"; then
      skipped+=("$v")
      continue
    fi
    if is_version_older "$v" "$active_version"; then
      to_remove+=("$v")
    fi
  done < <(list_installed_versions)

  if [[ ${#skipped[@]} -gt 0 ]]; then
    warn "Skipped non-semver versions (cannot compare): ${skipped[*]}"
  fi

  if [[ ${#to_remove[@]} -eq 0 ]]; then
    ok "Nothing to prune. No versions older than ${active_version}."
    exit 0
  fi

  info "The following versions will be removed:"
  for v in "${to_remove[@]}"; do
    local src pfx size="?"
    src="$(versioned_source "$v")"
    pfx="$(versioned_prefix "$v")"
    if command_exists du; then
      size="$(du -shc "$src" "$pfx" 2>/dev/null | tail -1 | cut -f1 || echo "?")"
    fi
    printf "  - %s  (%s)\n" "$v" "$size"
  done
  printf "\n"

  if [[ -n "$DRY_RUN" ]]; then
    for v in "${to_remove[@]}"; do
      dry "Would remove: source-${v}/ prefix-${v}/"
    done
    exit 0
  fi

  if [[ "$NON_INTERACTIVE" != "1" ]]; then
    printf "  Continue? [y/N] "
    read -r answer
    if [[ "$answer" != [yY] ]]; then
      info "Prune cancelled."
      exit 0
    fi
  fi

  for v in "${to_remove[@]}"; do
    local src pfx
    src="$(versioned_source "$v")"
    pfx="$(versioned_prefix "$v")"
    rm -rf "$src" "$pfx"
    ok "Removed: ${v}"
    remove_from_version_history "$v"
  done

  printf "\n"
  info "=== Prune complete: removed ${#to_remove[@]} version(s) ==="
  printf "\n"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local mode=""

  for arg in "$@"; do
    case "$arg" in
      --non-interactive) NON_INTERACTIVE=1 ;;
      --dry-run)         DRY_RUN=1 ;;
      --uninstall)       mode="uninstall" ;;
      --upgrade)         mode="upgrade" ;;
      --rollback)        mode="rollback" ;;
      --prune)           mode="prune" ;;
      --version | -v)
        printf "nemoclaw-installer v%s (safe)\n" "$NEMOCLAW_VERSION"
        exit 0
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        usage
        error "Unknown option: $arg"
        ;;
    esac
  done

  NON_INTERACTIVE="${NON_INTERACTIVE:-${NEMOCLAW_NON_INTERACTIVE:-}}"
  export NEMOCLAW_NON_INTERACTIVE="${NON_INTERACTIVE}"

  validate_nemoclaw_home
  acquire_lock

  if [[ -n "$DRY_RUN" ]]; then
    info "=== DRY RUN -- no changes will be made ==="
  fi

  case "$mode" in
    uninstall) do_uninstall ;;
    upgrade)   do_upgrade ;;
    rollback)  do_rollback ;;
    prune)     do_prune ;;
    "")
      # Default: fresh install
      print_banner

      step 1 3 "Node.js"
      check_nodejs

      step 2 3 "NemoClaw CLI"
      install_nemoclaw
      verify_nemoclaw

      step 3 3 "Onboarding"
      if command_exists nemoclaw; then
        run_onboard
      else
        warn "Skipping onboarding -- nemoclaw is not on PATH. Run 'nemoclaw onboard' after updating your PATH."
      fi

      print_done
      ;;
  esac
}

main "$@"
