#!/usr/bin/env bash
#
# Fail if a cluster's own files name a different cluster. A cluster copied
# from another and left with the source's name renders cleanly and points
# every Application at the source's overlays, so neither the render nor the
# placeholder check can see it.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="${SCRIPT_DIR}/.."

function echo_stderr() {
  echo "${*}" >&2
}

# The values of a YAML key in a file, one per line, with any list-item dash
# and trailing comment dropped.
function values_of() {
  local -r file="${1}"
  local -r key="${2}"
  awk -v key="${key}:" '
    { sub(/^[ \t]*(- )?/, "") }
    $1 == key { print $2 }
  ' "${file}"
}

# Checks that every value of a key in a file equals the expected one, and
# that there is at least one. Prints a line per problem.
function expect_values() {
  local -r file="${1}"
  local -r key="${2}"
  local -r expected="${3}"

  if [ ! -f "${file}" ]; then
    echo "  ${file}: missing"
    return 1
  fi

  local found=0 bad=0 value
  while IFS= read -r value; do
    [ -n "${value}" ] || continue
    found=1
    if [ "${value}" != "${expected}" ]; then
      echo "  ${file}: ${key} is ${value}, expected ${expected}"
      bad=1
    fi
  done < <(values_of "${file}" "${key}")

  if [ "${found}" -eq 0 ]; then
    echo "  ${file}: no ${key}, expected ${expected}"
    return 1
  fi
  return "${bad}"
}

function check_cluster() {
  local -r cluster="${1}"
  local -r dir="clusters/${cluster}"
  local failed=0

  expect_values "${dir}/patches/infra.appset.yaml" clusterName "${cluster}" || failed=1
  expect_values "${dir}/patches/argocd.app.yaml" value ".argocd/overlays/${cluster}" || failed=1
  expect_values "${dir}/root.app.yaml" path "clusters/${cluster}" || failed=1

  return "${failed}"
}

function main() {
  cd "${REPO_ROOT}"

  local failed=0 count=0
  local dir cluster problems
  for dir in clusters/*/; do
    [ -d "${dir}" ] || continue
    cluster="$(basename "${dir}")"
    count=$((count + 1))
    # every cluster is reported, so one fix pass can clear them all
    if problems="$(check_cluster "${cluster}")"; then
      echo "ok ${cluster}"
    else
      echo_stderr "cluster ${cluster} names another cluster in its own files:"
      echo_stderr "${problems}"
      failed=1
    fi
  done

  if [ "${count}" -eq 0 ]; then
    echo_stderr "no clusters found; is the repository layout intact?"
    return 1
  fi

  return "${failed}"
}

if [[ "${BASH_SOURCE[0]:-${0}}" == "${0}" ]]; then
  main "${@}"
fi
