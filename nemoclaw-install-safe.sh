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
#   - --uninstall support for clean removal
#   - --dry-run to preview actions without side effects
#
# Changes from upstream:
#   1. REMOVED: nvm auto-install (Node.js must already be on PATH)
#   2. REMOVED: Ollama auto-install
#   3. REMOVED: npm link (replaced with local --prefix install)
#   4. ADDED:   --uninstall, --dry-run flags
#   5. ADDED:   trap cleanup on error
#   6. ADDED:   git clone commit hash recording

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DEFAULT_NEMOCLAW_VERSION="0.1.0"
TOTAL_STEPS=3

# All NemoClaw artifacts live under this single directory.
NEMOCLAW_HOME="${NEMOCLAW_HOME:-${HOME}/.nemoclaw}"
NEMOCLAW_SOURCE="${NEMOCLAW_HOME}/source"
NEMOCLAW_PREFIX="${NEMOCLAW_HOME}/prefix"
NEMOCLAW_BIN="${NEMOCLAW_PREFIX}/bin"

# Flags
DRY_RUN=""
NON_INTERACTIVE=""

# Track partial install for cleanup
_INSTALL_STARTED=""
_INSTALL_START=""
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
  local n=$1 msg=$2
  printf "\n${C_GREEN}[%s/%s]${C_RESET} ${C_BOLD}%s${C_RESET}\n" \
    "$n" "$TOTAL_STEPS" "$msg"
  printf "  ${C_DIM}------------------------------------------------------${C_RESET}\n"
}

command_exists() { command -v "$1" &>/dev/null; }

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
# Backup / restore for safe reinstall
# ---------------------------------------------------------------------------
backup_existing() {
  if [[ -d "$NEMOCLAW_SOURCE" || -d "$NEMOCLAW_PREFIX" ]]; then
    _BACKUP_DIR="${NEMOCLAW_HOME}/.backup-$(date +%s)-$$"
    mkdir -p "$_BACKUP_DIR"
    info "Existing installation detected -- backing up to $_BACKUP_DIR"
    if [[ -d "$NEMOCLAW_SOURCE" ]]; then mv "$NEMOCLAW_SOURCE" "$_BACKUP_DIR/source"; fi
    if [[ -d "$NEMOCLAW_PREFIX" ]]; then mv "$NEMOCLAW_PREFIX" "$_BACKUP_DIR/prefix"; fi
  fi
}

restore_from_backup() {
  if [[ -n "$_BACKUP_DIR" && -d "$_BACKUP_DIR" ]]; then
    warn "Restoring previous installation from backup..."
    if [[ -d "$_BACKUP_DIR/source" ]]; then
      rm -rf "$NEMOCLAW_SOURCE"
      mv "$_BACKUP_DIR/source" "$NEMOCLAW_SOURCE"
    fi
    if [[ -d "$_BACKUP_DIR/prefix" ]]; then
      rm -rf "$NEMOCLAW_PREFIX"
      mv "$_BACKUP_DIR/prefix" "$NEMOCLAW_PREFIX"
    fi
    rm -rf "$_BACKUP_DIR"
    info "Previous installation restored."
  fi
}

remove_backup() {
  if [[ -n "$_BACKUP_DIR" && -d "$_BACKUP_DIR" ]]; then
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
    # Remove the failed partial artifacts
    if [[ -d "$NEMOCLAW_SOURCE" ]]; then rm -rf "$NEMOCLAW_SOURCE"; fi
    if [[ -d "$NEMOCLAW_PREFIX" ]]; then rm -rf "$NEMOCLAW_PREFIX"; fi
    # Restore previous working installation if we had one
    restore_from_backup
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
  info "=== Installation complete ==="
  printf "\n"
  printf "  ${C_GREEN}${C_BOLD}NemoClaw${C_RESET}  ${C_DIM}(%ss)${C_RESET}\n" "$elapsed"
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
  printf "    --uninstall          Remove NemoClaw and all its artifacts\n"
  printf "    --version, -v        Print installer version and exit\n"
  printf "    --help, -h           Show this help message and exit\n\n"
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

  # Back up existing installation before touching anything
  backup_existing

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
      dry "Would install from current directory to $NEMOCLAW_PREFIX"
    else
      dry "Would clone https://github.com/NVIDIA/NemoClaw.git to $NEMOCLAW_SOURCE"
      dry "Would install dependencies with --ignore-scripts"
      dry "Would build nemoclaw plugin"
      dry "Would install CLI to $NEMOCLAW_PREFIX (npm --prefix)"
    fi
    return 0
  fi

  local src_dir
  if [[ "$install_from_source" == "local" ]]; then
    src_dir="$(pwd)"
  else
    rm -rf "$NEMOCLAW_SOURCE"
    mkdir -p "$(dirname "$NEMOCLAW_SOURCE")"
    local git_ref="${NEMOCLAW_GIT_REF:-}"
    if [[ -n "$git_ref" ]]; then
      spin "Cloning NemoClaw source (ref: ${git_ref})" git clone --depth 1 --branch "$git_ref" https://github.com/NVIDIA/NemoClaw.git "$NEMOCLAW_SOURCE"
    else
      spin "Cloning NemoClaw source (HEAD)" git clone --depth 1 https://github.com/NVIDIA/NemoClaw.git "$NEMOCLAW_SOURCE"
    fi

    # Record the commit hash for audit/reproducibility
    local commit_hash
    commit_hash="$(git -C "$NEMOCLAW_SOURCE" rev-parse HEAD 2>/dev/null || echo "unknown")"
    printf "%s\n" "$commit_hash" > "${NEMOCLAW_SOURCE}/.install-commit"
    info "Cloned at commit: ${commit_hash}"
    if [[ -z "$git_ref" ]]; then
      warn "No NEMOCLAW_GIT_REF set -- cloned unpinned HEAD. Consider setting NEMOCLAW_GIT_REF=v<version> for reproducibility."
    fi

    src_dir="$NEMOCLAW_SOURCE"
  fi

  spin "Preparing OpenClaw package" bash -c "$(declare -p C_CYAN C_YELLOW C_RED C_GREEN C_DIM C_RESET 2>/dev/null || true); $(declare -f command_exists info warn pre_extract_openclaw); pre_extract_openclaw \"\$1\"" _ "$src_dir" \
    || warn "Pre-extraction failed -- npm install may fail if openclaw tarball is broken"

  spin "Installing NemoClaw dependencies" bash -c "cd \"\$1\" && npm install --ignore-scripts" _ "$src_dir"
  spin "Building NemoClaw plugin" bash -c "cd \"\$1\"/nemoclaw && npm install --ignore-scripts && npm run build" _ "$src_dir"

  # Install to local prefix instead of global npm link
  mkdir -p "$NEMOCLAW_PREFIX"
  spin "Installing NemoClaw CLI to local prefix" bash -c "cd \"\$1\" && npm install --global --prefix \"\$2\" --ignore-scripts ." _ "$src_dir" "$NEMOCLAW_PREFIX"

  # Fallback: if package.json has no "bin" field, npm won't create bin/nemoclaw.
  # Create a manual wrapper in that case.
  if [[ ! -x "${NEMOCLAW_BIN}/nemoclaw" ]]; then
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
      mkdir -p "$NEMOCLAW_BIN"
      cat > "${NEMOCLAW_BIN}/nemoclaw" <<SHIM
#!/usr/bin/env bash
exec node "${src_dir}/${main_entry}" "\$@"
SHIM
      chmod +x "${NEMOCLAW_BIN}/nemoclaw"
      info "Created manual wrapper at ${NEMOCLAW_BIN}/nemoclaw -> ${src_dir}/${main_entry}"
    fi
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
# Main
# ---------------------------------------------------------------------------
main() {
  local do_uninstall=""

  for arg in "$@"; do
    case "$arg" in
      --non-interactive) NON_INTERACTIVE=1 ;;
      --dry-run)         DRY_RUN=1 ;;
      --uninstall)       do_uninstall=1 ;;
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

  if [[ -n "$do_uninstall" ]]; then
    do_uninstall
  fi

  if [[ -n "$DRY_RUN" ]]; then
    info "=== DRY RUN -- no changes will be made ==="
  fi

  print_banner

  step 1 "Node.js"
  check_nodejs

  step 2 "NemoClaw CLI"
  install_nemoclaw
  verify_nemoclaw

  step 3 "Onboarding"
  if command_exists nemoclaw; then
    run_onboard
  else
    warn "Skipping onboarding -- nemoclaw is not on PATH. Run 'nemoclaw onboard' after updating your PATH."
  fi

  print_done
}

main "$@"
