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

# The items of a YAML list in the front matter, one per line.
function read_front_matter_list() {
  local -r readme="${1}"
  local -r key="${2}"
  awk -v key="${key}:" '
    NR == 1 && $0 != "---" { exit }
    NR == 1 { in_front_matter = 1; next }
    in_front_matter && $0 == "---" { exit }
    !in_front_matter { next }
    in_list && $1 == "-" { print $2; next }
    { in_list = ($1 == key) }
  ' "${readme}"
}

# The `.argocd/overlays/shared-patches/<env>` directories a cluster's Argo CD
# overlay references, one per line. Empty when the overlay references none, or
# when there is no such overlay.
function shared_patch_envs_for() {
  local -r cluster="${1}"
  local -r kustomization=".argocd/overlays/${cluster}/kustomization.yaml"
  [ -f "${kustomization}" ] || return 0
  sed -n 's|.*shared-patches/\([^/]*\)/.*|\1|p' "${kustomization}" | sort -u
}

# Every tracked YAML a cluster reads: its own directories, the shared files
# and AppProjects every cluster inherits, and the base and shared patches of the applications
# this cluster actually runs. An application the cluster does not run is not
# scanned, because its placeholders are not the cluster's to fill.
#
# These are git pathspecs, not shell globs, and git matches `*` across `/`, so
# `apps/x/base/*.yaml` reaches nested files. `.github/` is deliberately absent,
# its marker being a workflow note rather than a placeholder.
function set_scan_paths_for() {
  local -r cluster="${1}"
  shift
  local -r apps=("${@}")
  local base app env
  scan_paths=()
  for base in \
    "clusters/${cluster}/" \
    ".argocd/overlays/${cluster}/" \
    "shared-patches/" \
    "appprojects/"; do
    scan_paths+=("${base}*.yaml" "${base}*.yml")
  done
  # only the shared Argo CD patches this cluster's overlay actually reads, for
  # the same reason applications are scoped: another environment's placeholder
  # is not this cluster's to fill
  while IFS= read -r env; do
    [ -n "${env}" ] || continue
    scan_paths+=(".argocd/overlays/shared-patches/${env}/*.yaml"
      ".argocd/overlays/shared-patches/${env}/*.yml")
  done < <(shared_patch_envs_for "${cluster}")
  for app in "${apps[@]}"; do
    for base in \
      "apps/${app}/base/" \
      "apps/${app}/shared-patches/" \
      "apps/${app}/overlays/${cluster}/"; do
      scan_paths+=("${base}*.yaml" "${base}*.yml")
    done
  done
}

# An application with an overlay for this cluster that the cluster neither
# runs nor lists as disabled is not scanned, so say so. The lists are
# maintained by hand and a stale one would narrow the check silently.
function warn_undeclared_overlays() {
  local -r cluster="${1}"
  shift
  local -r apps=("${@}")
  local dir app declared
  for dir in apps/*/overlays/"${cluster}"; do
    [ -d "${dir}" ] || continue
    app="${dir#apps/}"
    app="${app%%/*}"
    declared=0
    for a in "${apps[@]}"; do
      [ "${a}" = "${app}" ] && declared=1 && break
    done
    if [ "${declared}" -eq 0 ]; then
      echo "note: ${cluster} has an overlay for ${app} but lists it under neither apps nor disabled in its README; not scanned"
    fi
  done
}

function main() {
  if ! is_cmd_available git; then
    echo_stderr "required command not found on PATH: git"
    return 1
  fi

  cd "${REPO_ROOT}"

  local complete=()
  local readme cluster status app a
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
  local -a scan_paths apps known
  local hits status
  for cluster in "${complete[@]}"; do
    apps=()
    while IFS= read -r app; do
      [ -n "${app}" ] && apps+=("${app}")
    done < <(read_front_matter_list "clusters/${cluster}/README.md" apps)
    if [ "${#apps[@]}" -eq 0 ]; then
      echo_stderr "no apps list in the front matter of clusters/${cluster}/README.md"
      return 1
    fi
    # an overlay kept for later, such as an optional application, is named
    # under `disabled` so that it is neither scanned nor noted
    known=("${apps[@]}")
    while IFS= read -r app; do
      [ -n "${app}" ] && known+=("${app}")
    done < <(read_front_matter_list "clusters/${cluster}/README.md" disabled)
    warn_undeclared_overlays "${cluster}" "${known[@]}"
    set_scan_paths_for "${cluster}" "${apps[@]}"
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
