#!/usr/bin/env bash
set -euo pipefail

LOCALVLLM_REPO_URL="${LOCALVLLM_REPO_URL:-https://github.com/hossbit/local-ai-server-vllm.git}"
LOCALVLLM_TARBALL_BASE="${LOCALVLLM_TARBALL_BASE:-https://github.com/hossbit/local-ai-server-vllm/archive}"
LOCALVLLM_REF="${LOCALVLLM_REF:-main}"

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
  case "$LOCALVLLM_REF" in
    v*|refs/tags/*)
      printf '%s/refs/tags/%s.tar.gz\n' "$LOCALVLLM_TARBALL_BASE" "${LOCALVLLM_REF#refs/tags/}"
      ;;
    refs/heads/*)
      printf '%s/%s.tar.gz\n' "$LOCALVLLM_TARBALL_BASE" "$LOCALVLLM_REF"
      ;;
    *)
      printf '%s/refs/heads/%s.tar.gz\n' "$LOCALVLLM_TARBALL_BASE" "$LOCALVLLM_REF"
      ;;
  esac
}

usage() {
  cat <<EOF
Usage: curl -fsSL https://raw.githubusercontent.com/hossbit/local-ai-server-vllm/main/install.sh | bash

Custom install directory:
  curl -fsSL https://raw.githubusercontent.com/hossbit/local-ai-server-vllm/main/install.sh | LOCALVLLM_DIR="\$HOME/ai-vllm" bash

Install both isolated backends:
  curl -fsSL https://raw.githubusercontent.com/hossbit/local-ai-server-vllm/main/install.sh | bash -s -- --all

Install only vLLM-Omni:
  curl -fsSL https://raw.githubusercontent.com/hossbit/local-ai-server-vllm/main/install.sh | bash -s -- --backend omni

Environment:
  LOCALVLLM_DIR         Install directory. Default: ~/ai-vllm
  LOCALVLLM_REF         Git branch or tag to install. Default: main
  LOCALVLLM_REPO_URL    Git repository URL. Default: $LOCALVLLM_REPO_URL
EOF
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

log "Installing Local vLLM from ${LOCALVLLM_REPO_URL} (${LOCALVLLM_REF})"

if have git; then
  git clone --depth 1 --branch "$LOCALVLLM_REF" "$LOCALVLLM_REPO_URL" "$source_dir"
else
  have tar || fail "git or tar is required."
  archive_file="$tmp_dir/localvllm.tar.gz"
  curl -fsSL "$(archive_url)" -o "$archive_file"
  mkdir -p "$source_dir"
  tar -xzf "$archive_file" -C "$tmp_dir"
  extracted="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
    [ -f "$dir/install-localvllm.sh" ] && { printf '%s\n' "$dir"; break; }
  done)"
  [[ -n "${extracted:-}" ]] || fail "Could not find the extracted Local vLLM source directory."
  rm -rf "$source_dir"
  mv "$extracted" "$source_dir"
fi

[[ -x "$source_dir/install-localvllm.sh" ]] || fail "Installer not found: $source_dir/install-localvllm.sh"

bash "$source_dir/install-localvllm.sh" "$@"

log "Done. Try: localvllm backend list"
