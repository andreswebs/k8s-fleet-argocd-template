#!/usr/bin/env bash
#
# Build every overlay in the repository with the flags Argo CD uses, so a
# change that breaks a render is caught before it reaches a cluster.

set -o errexit
set -o nounset
set -o pipefail

readonly KUSTOMIZE_FLAGS=(--enable-helm --load-restrictor LoadRestrictionsNone)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="${SCRIPT_DIR}/.."

function echo_stderr() {
  echo "${*}" >&2
}

function usage() {
  cat <<'EOF'
Usage: scripts/render-all.sh [--out DIR]

Builds every kustomization under .argocd/overlays, clusters and
apps/*/overlays with the flags Argo CD renders with, and exits non-zero on
the first overlay that fails, naming it.

Options:
  --out DIR   Also write each rendered overlay to DIR as a single YAML file
              named after the overlay path, for inspection or diffing.
  -h, --help  Print this message.
EOF
}

function is_cmd_available() {
  command -v "${1}" >/dev/null 2>&1
}

function check_dependencies() {
  local missing=0
  local cmd
  for cmd in kustomize helm; do
    if ! is_cmd_available "${cmd}"; then
      echo_stderr "required command not found on PATH: ${cmd}"
      missing=1
    fi
  done
  return "${missing}"
}

# Overlay directories, repository-relative and sorted, one per line. The
# shared-patches directories carry no kustomization.yaml and drop out here.
function find_overlays() {
  local pattern
  for pattern in ".argocd/overlays/*" "clusters/*" "apps/*/overlays/*"; do
    # shellcheck disable=SC2086
    find ${pattern} -maxdepth 1 -name kustomization.yaml -print 2>/dev/null
  done | sed 's|/kustomization.yaml$||' | sort
}

function render_overlay() {
  local -r overlay="${1}"
  local -r out_dir="${2}"

  if [ -z "${out_dir}" ]; then
    kustomize build "${KUSTOMIZE_FLAGS[@]}" "${overlay}" >/dev/null
    return
  fi

  # the leading dot of .argocd/... is dropped so the output is not a hidden file
  local name="${overlay#.}"
  name="${name//\//-}"
  kustomize build "${KUSTOMIZE_FLAGS[@]}" "${overlay}" >"${out_dir}/${name}.yaml"
}

function main() {
  local out_dir=""

  while [ "${#}" -gt 0 ]; do
    case "${1}" in
    --out)
      if [ "${#}" -lt 2 ]; then
        echo_stderr "--out requires a directory argument"
        return 2
      fi
      out_dir="${2}"
      shift 2
      ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      echo_stderr "unknown argument: ${1}"
      usage >&2
      return 2
      ;;
    esac
  done

  if ! check_dependencies; then
    return 1
  fi

  cd "${REPO_ROOT}"

  if [ -n "${out_dir}" ] && ! mkdir -p "${out_dir}"; then
    echo_stderr "cannot create output directory: ${out_dir}"
    return 1
  fi

  local overlays
  overlays="$(find_overlays)"
  if [ -z "${overlays}" ]; then
    echo_stderr "no overlays found; is the repository layout intact?"
    return 1
  fi

  local count=0
  local overlay
  while IFS= read -r overlay; do
    [ -z "${overlay}" ] && continue
    if ! render_overlay "${overlay}" "${out_dir}"; then
      echo_stderr "render failed: ${overlay} (${count} overlays rendered before it)"
      return 1
    fi
    count=$((count + 1))
    echo "ok ${overlay}"
  done <<<"${overlays}"

  echo "rendered ${count} overlays"
}

if [[ "${BASH_SOURCE[0]:-${0}}" == "${0}" ]]; then
  main "${@}"
fi
