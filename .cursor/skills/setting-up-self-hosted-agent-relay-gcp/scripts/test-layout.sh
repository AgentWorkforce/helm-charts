#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=resolve-layout.sh
source "$script_dir/resolve-layout.sh"

fail() {
  printf 'test-layout: FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local actual=$1
  local expected=$2
  local label=$3
  test "$actual" = "$expected" ||
    fail "$label: expected '$expected', got '$actual'"
}

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

repo="$test_root/source repository"
mkdir -p "$repo/charts/agent-relay" "$repo/charts/96bulls" "$repo/scripts/ci"
: >"$repo/charts/agent-relay/Chart.yaml"
: >"$repo/charts/agent-relay/values-gcp-proof.yaml"
: >"$repo/charts/96bulls/Chart.yaml"
: >"$repo/scripts/ci/charts.sh"

resolve_agent_relay_layout "$repo"
assert_equal "$AGENT_RELAY_LAYOUT" repository "repository layout"
assert_equal "$AGENT_RELAY_CHART_PATH" "$repo/charts/agent-relay" "repository chart"
assert_equal "$AGENT_RELAY_96BULLS_CHART" "$repo/charts/96bulls" "96bulls chart"
assert_equal "$AGENT_RELAY_STATIC_CHECK" "$repo/scripts/ci/charts.sh" "static check"

bundle="$test_root/customer bundle"
mkdir -p "$bundle/nested/work"
: >"$bundle/agent-relay-0.1.0.tgz"
: >"$bundle/values-gcp-proof.yaml"

resolve_agent_relay_layout "$bundle"
assert_equal "$AGENT_RELAY_LAYOUT" standalone "standalone layout"
assert_equal "$AGENT_RELAY_CHART_PATH" "$bundle/agent-relay-0.1.0.tgz" "packaged chart"
assert_equal "$AGENT_RELAY_BASE_VALUES_FILE" "$bundle/values-gcp-proof.yaml" "bundle values"
assert_equal "$AGENT_RELAY_STATIC_CHECK" "" "standalone static check"

layout_exports=$(bash "$script_dir/resolve-layout.sh" "$bundle")
eval "$layout_exports"
assert_equal "$AGENT_RELAY_CHART_PATH" "$bundle/agent-relay-0.1.0.tgz" \
  "executable export with spaces"

if command -v zsh >/dev/null 2>&1; then
  SKILL_RESOLVER="$script_dir/resolve-layout.sh" \
    BUNDLE_ROOT="$bundle" \
    EXPECTED_CHART="$bundle/agent-relay-0.1.0.tgz" \
    zsh -c '
      layout_exports=$(bash "$SKILL_RESOLVER" "$BUNDLE_ROOT") || exit
      eval "$layout_exports"
      [[ "$AGENT_RELAY_CHART_PATH" == "$EXPECTED_CHART" ]]
    ' || fail "zsh could not import resolver exports"
fi

(
  cd "$bundle/nested/work"
  resolve_agent_relay_layout
  assert_equal "$AGENT_RELAY_ROOT" "$bundle" "ancestor discovery"
)

mkdir -p "$bundle/agent-relay"
: >"$bundle/agent-relay/Chart.yaml"
resolve_agent_relay_layout "$bundle"
assert_equal "$AGENT_RELAY_CHART_PATH" "$bundle/agent-relay" "extracted chart preference"

ambiguous="$test_root/ambiguous"
mkdir -p "$ambiguous"
: >"$ambiguous/values-gcp-proof.yaml"
: >"$ambiguous/agent-relay-0.1.0.tgz"
: >"$ambiguous/agent-relay-0.2.0.tgz"
if resolve_agent_relay_layout "$ambiguous" >/dev/null 2>&1; then
  fail "multiple packaged charts should be rejected"
fi

missing="$test_root/missing"
mkdir -p "$missing"
if resolve_agent_relay_layout "$missing" >/dev/null 2>&1; then
  fail "an explicit invalid root should be rejected"
fi

printf '%s\n' \
  'test-layout: PASS (repository, standalone, extracted, discovery, shell exports, rejection)'
