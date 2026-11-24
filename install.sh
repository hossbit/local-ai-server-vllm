#!/usr/bin/env bash
set -euo pipefail

LOCALVLLM_REPO_URL="${LOCALVLLM_REPO_URL:-https://github.com/hossbit/local-ai-server-vllm.git}"
LOCALVLLM_TARBALL_BASE="${LOCALVLLM_TARBALL_BASE:-https://github.com/hossbit/local-ai-server-vllm/archive}"
LOCALVLLM_LATEST_API="${LOCALVLLM_LATEST_API:-https://api.github.com/repos/hossbit/local-ai-server-vllm/releases/latest}"
# Install the newest release, never whatever is on main at fetch time. When the
# GitHub API cannot be reached (offline mirror, rate limit) the release this
# script shipped with is used. Override LOCALVLLM_REF to test another tag/branch.
LOCALVLLM_REF="${LOCALVLLM_REF:-latest}"
LOCALVLLM_FALLBACK_REF="${LOCALVLLM_FALLBACK_REF:-v1.5.0}"

log() {
  printf 'localvllm-install: %s\n' "$*"
}

fail() {
  printf 'localvllm-install: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

archive_url() {
  # GitHub resolves unqualified branches and tags; explicit refs stay explicit.
  printf '%s/%s.tar.gz\n' "${LOCALVLLM_TARBALL_BASE}" "${LOCALVLLM_REF:-main}"
}

usage() {
  cat <<EOF
Usage: curl -fsSL https://hossbit.github.io/localvllm/install.sh | bash

Custom install directory:
  curl -fsSL https://hossbit.github.io/localvllm/install.sh | LOCALVLLM_DIR="\$HOME/ai-vllm" bash

Install both isolated backends:
  curl -fsSL https://hossbit.github.io/localvllm/install.sh | bash -s -- --all

Install only vLLM-Omni:
  curl -fsSL https://hossbit.github.io/localvllm/install.sh | bash -s -- --backend omni

Environment:
  LOCALVLLM_DIR         Install directory. Default: ~/ai-vllm
  LOCALVLLM_REF         Git branch or tag to install. Default: latest release
  LOCALVLLM_REPO_URL    Git repository URL. Default: $LOCALVLLM_REPO_URL
EOF
}

resolve_ref() {
  local latest_json latest_ref=""

  [ "$LOCALVLLM_REF" = "latest" ] || return 0

  log "Resolving latest Local vLLM release"
  if latest_json="$(curl -fsSL "$LOCALVLLM_LATEST_API" 2>/dev/null)"; then
    latest_ref="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$latest_json" | head -n 1)"
  fi
  if [ -z "$latest_ref" ]; then
    log "Could not look up the latest release; using ${LOCALVLLM_FALLBACK_REF}"
    latest_ref="$LOCALVLLM_FALLBACK_REF"
  fi
  LOCALVLLM_REF="$latest_ref"
}

# Minimal server and container images often ship without git and tar. Install
# tar with the system package manager (the main installer needs sudo for its
# own packages anyway) instead of stopping before anything happened.
ensure_tar() {
  local sudo_cmd=()

  have tar && return 0
  if [ "$(id -u)" -ne 0 ]; then
    have sudo || fail "tar is required. Install it (for example: dnf install tar), then rerun."
    sudo_cmd=(sudo)
  fi

  log "Installing tar, which this installer needs"
  if have apt-get; then
    "${sudo_cmd[@]}" apt-get install -y tar
  elif have dnf; then
    "${sudo_cmd[@]}" dnf install -y tar
  elif have yum; then
    "${sudo_cmd[@]}" yum install -y tar
  elif have zypper; then
    "${sudo_cmd[@]}" zypper --non-interactive install tar
  else
    fail "tar is required. Install it with your package manager, then rerun."
  fi
  have tar || fail "tar is still missing. Install it with your package manager, then rerun."
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

have bash || fail "bash is required."
have curl || fail "curl is required."
have mktemp || fail "mktemp is required."

# Running from a checkout should use that checkout, not the published repo.
script_path="${BASH_SOURCE[0]:-}"
if [ -n "$script_path" ] && [ -f "$script_path" ]; then
  script_dir="$(cd "$(dirname "$script_path")" && pwd)"
  if [ -x "$script_dir/install-localvllm.sh" ]; then
    log "Using local checkout: $script_dir"
    exec bash "$script_dir/install-localvllm.sh" "$@"
  fi
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

source_dir="$tmp_dir/localvllm-source"

resolve_ref
log "Installing Local vLLM from ${LOCALVLLM_REPO_URL} (${LOCALVLLM_REF})"

if have git; then
  clone_ref="${LOCALVLLM_REF#refs/heads/}"
  clone_ref="${clone_ref#refs/tags/}"
  git clone --depth 1 --branch "$clone_ref" "$LOCALVLLM_REPO_URL" "$source_dir"
else
  ensure_tar
  archive_file="$tmp_dir/localvllm.tar.gz"
  curl -fsSL "$(archive_url)" -o "$archive_file"
  mkdir -p "$source_dir"
  tar -xzf "$archive_file" --strip-components=1 -C "$source_dir"
fi

[[ -x "$source_dir/install-localvllm.sh" ]] || fail "Installer not found: $source_dir/install-localvllm.sh"

# The checkout is deleted on exit, so the installer's retry hints must name
# this one-line command instead of its own temporary path.
LOCALVLLM_BOOTSTRAP=1 bash "$source_dir/install-localvllm.sh" "$@"

log "Done. Try: localvllm backend list"
