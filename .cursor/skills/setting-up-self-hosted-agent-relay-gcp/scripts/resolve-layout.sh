#!/usr/bin/env bash

# Resolve either the source-repository layout or the standalone customer
# handoff layout. Source this file and call resolve_agent_relay_layout so the
# resolved paths remain available to the caller.

_agent_relay_layout_error() {
  printf 'resolve-layout: %s\n' "$*" >&2
  return 1
}

_agent_relay_canonical_dir() {
  (cd -- "$1" 2>/dev/null && pwd -P)
}

_agent_relay_try_root() {
  local root=$1
  local candidate
  local packages=()

  root=$(_agent_relay_canonical_dir "$root") || return 1

  if test -f "$root/charts/agent-relay/Chart.yaml" &&
    test -f "$root/charts/agent-relay/values-gcp-proof.yaml"; then
    AGENT_RELAY_LAYOUT=repository
    AGENT_RELAY_ROOT=$root
    AGENT_RELAY_CHART_PATH=$root/charts/agent-relay
    AGENT_RELAY_BASE_VALUES_FILE=$root/charts/agent-relay/values-gcp-proof.yaml
    AGENT_RELAY_96BULLS_CHART=
    AGENT_RELAY_STATIC_CHECK=

    if test -f "$root/charts/96bulls/Chart.yaml"; then
      AGENT_RELAY_96BULLS_CHART=$root/charts/96bulls
    fi
    if test -f "$root/scripts/ci/charts.sh"; then
      AGENT_RELAY_STATIC_CHECK=$root/scripts/ci/charts.sh
    fi
    return 0
  fi

  test -f "$root/values-gcp-proof.yaml" || return 1

  if test -f "$root/agent-relay/Chart.yaml"; then
    AGENT_RELAY_CHART_PATH=$root/agent-relay
  else
    for candidate in "$root"/agent-relay-*.tgz; do
      test -f "$candidate" && packages+=("$candidate")
    done
    ((${#packages[@]} == 1)) || return 1
    AGENT_RELAY_CHART_PATH=${packages[0]}
  fi

  AGENT_RELAY_LAYOUT=standalone
  AGENT_RELAY_ROOT=$root
  AGENT_RELAY_BASE_VALUES_FILE=$root/values-gcp-proof.yaml
  AGENT_RELAY_96BULLS_CHART=
  AGENT_RELAY_STATIC_CHECK=
  return 0
}

_agent_relay_add_ancestors() {
  local current=$1
  local parent

  current=$(_agent_relay_canonical_dir "$current") || return 0
  while :; do
    _AGENT_RELAY_CANDIDATES+=("$current")
    parent=${current%/*}
    test -n "$parent" || parent=/
    test "$parent" != "$current" || break
    current=$parent
  done
}

resolve_agent_relay_layout() {
  local explicit_root=${1:-}
  local script_dir
  local candidate
  local seen=':'

  AGENT_RELAY_LAYOUT=
  AGENT_RELAY_ROOT=
  AGENT_RELAY_CHART_PATH=
  AGENT_RELAY_BASE_VALUES_FILE=
  AGENT_RELAY_96BULLS_CHART=
  AGENT_RELAY_STATIC_CHECK=

  if test -n "$explicit_root"; then
    if ! _agent_relay_try_root "$explicit_root"; then
      _agent_relay_layout_error \
        "HANDOFF_ROOT is not a repository or standalone handoff root: $explicit_root"
      return 1
    fi
  else
    _AGENT_RELAY_CANDIDATES=()
    script_dir=$(
      cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P
    ) || {
      _agent_relay_layout_error "cannot determine the skill script directory"
      return 1
    }

    _agent_relay_add_ancestors "$PWD"
    _agent_relay_add_ancestors "$script_dir"

    for candidate in "${_AGENT_RELAY_CANDIDATES[@]}"; do
      case "$seen" in
        *":$candidate:"*) continue ;;
      esac
      seen="${seen}${candidate}:"
      if _agent_relay_try_root "$candidate"; then
        break
      fi
    done
    unset _AGENT_RELAY_CANDIDATES

    if test -z "${AGENT_RELAY_LAYOUT:-}"; then
      _agent_relay_layout_error \
        "no layout found; set HANDOFF_ROOT to the extracted handoff or repository root"
      return 1
    fi
  fi

  export AGENT_RELAY_LAYOUT AGENT_RELAY_ROOT AGENT_RELAY_CHART_PATH
  export AGENT_RELAY_BASE_VALUES_FILE AGENT_RELAY_96BULLS_CHART
  export AGENT_RELAY_STATIC_CHECK
}

_agent_relay_print_exports() {
  local name
  for name in \
    AGENT_RELAY_LAYOUT \
    AGENT_RELAY_ROOT \
    AGENT_RELAY_CHART_PATH \
    AGENT_RELAY_BASE_VALUES_FILE \
    AGENT_RELAY_96BULLS_CHART \
    AGENT_RELAY_STATIC_CHECK; do
    printf 'export %s=%q\n' "$name" "${!name}"
  done
}

if test "${BASH_SOURCE[0]}" = "$0"; then
  resolve_agent_relay_layout "${1:-}" || exit 1
  _agent_relay_print_exports
fi
