#!/usr/bin/env bash
#
# Fail if a cluster that declares itself complete still reads a placeholder.
# Clusters marked `status: template` in their README front matter are the
# template's own examples and are expected to be full of them.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="${SCRIPT_DIR}/.."
readonly MARKER="TODO"

function echo_stderr() {
  echo "${*}" >&2
}

function is_cmd_available() {
  command -v "${1}" >/dev/null 2>&1
}

# The value of `status` in the YAML front matter between the first two `---`
# lines of a README, or the empty string if there is no front matter.
function read_status() {
  local -r readme="${1}"
  awk '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { in_front_matter = 1; next }
    in_front_matter && $0 == "---" { exit }
    in_front_matter && $1 == "status:" { print $2; exit }
  ' "${readme}"
}

# Every tracked YAML a cluster reads: its own directories, plus the shared
# files each cluster inherits. These are git pathspecs, not shell globs, and
# git matches `*` across `/`, so `apps/*/base/*.yaml` reaches nested files.
# Assigns to the caller's `scan_paths` array; `.github/` is deliberately
# absent, its marker being a workflow note rather than a placeholder.
function set_scan_paths_for() {
  local -r cluster="${1}"
  local base
  scan_paths=()
  for base in \
    "clusters/${cluster}/" \
    ".argocd/overlays/${cluster}/" \
    "shared-patches/" \
    ".argocd/overlays/shared-patches/" \
    "apps/*/base/" \
    "apps/*/shared-patches/" \
    "apps/*/overlays/${cluster}/"; do
    scan_paths+=("${base}*.yaml" "${base}*.yml")
  done
}

function main() {
  if ! is_cmd_available git; then
    echo_stderr "required command not found on PATH: git"
    return 1
  fi

  cd "${REPO_ROOT}"

  local complete=()
  local readme cluster status
  for readme in clusters/*/README.md; do
    [ -f "${readme}" ] || continue
    cluster="$(basename "$(dirname "${readme}")")"
    status="$(read_status "${readme}")"
    if [ -z "${status}" ]; then
      echo_stderr "no status in the front matter of ${readme}"
      return 1
    fi
    if [ "${status}" = "complete" ]; then
      complete+=("${cluster}")
    fi
  done

  if [ "${#complete[@]}" -eq 0 ]; then
    echo "no cluster is marked complete; nothing to check"
    return 0
  fi

  local failed=0
  local -a scan_paths
  local hits status
  for cluster in "${complete[@]}"; do
    set_scan_paths_for "${cluster}"
    # every complete cluster is reported, so one fix pass can clear them all
    status=0
    hits="$(git grep -n -e "${MARKER}" -- "${scan_paths[@]}")" || status="${?}"
    if [ "${status}" -gt 1 ]; then
      echo_stderr "git grep failed while scanning cluster ${cluster}"
      return 1
    fi
    if [ -n "${hits}" ]; then
      echo_stderr "cluster ${cluster} is marked complete but still has placeholders:"
      echo_stderr "${hits}"
      failed=1
    else
      echo "ok ${cluster}"
    fi
  done

  return "${failed}"
}

if [[ "${BASH_SOURCE[0]:-${0}}" == "${0}" ]]; then
  main "${@}"
fi
