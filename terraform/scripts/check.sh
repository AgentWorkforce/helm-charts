#!/usr/bin/env bash
# Static checks for every Terraform module and example, with no cloud
# credentials: fmt, init (no backend), validate, tflint, terraform test (mock
# providers), terraform-docs drift and checkov. Each tool is skipped with a
# notice when it is not installed, unless CI=true, where a missing tool fails.
#
#   terraform/scripts/check.sh            # all checks
#   TF_BIN=tofu terraform/scripts/check.sh validate test   # OpenTofu, selected checks
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_BIN="${TF_BIN:-terraform}"
CHECKS=("$@")
[ ${#CHECKS[@]} -gt 0 ] || CHECKS=(fmt validate tflint test docs checkov)
export TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

dirs=()
while IFS= read -r d; do dirs+=("$d"); done < <(cd "$ROOT" && find modules examples -not -path '*/.terraform/*' \( -name versions.tf -o \( -name main.tf -path 'examples/*' \) \) | xargs -n1 dirname | sort -u)

want() { local c; for c in "${CHECKS[@]}"; do [ "$c" = "$1" ] && return 0; done; return 1; }
have() {
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ "${CI:-}" = "true" ]; then echo "::error::$1 is not installed"; exit 1; fi
  echo "skip: $1 not installed"; return 1
}

fail=0
run() { echo "+ $*"; "$@" || { echo "::error::failed: $*"; fail=1; }; }

if want fmt; then run "$TF_BIN" fmt -check -recursive -diff "$ROOT"; fi

for d in "${dirs[@]}"; do
  echo "== $d"
  if want validate || want test; then
    (cd "$ROOT/$d" && "$TF_BIN" init -backend=false -input=false -no-color >/dev/null) || { echo "::error::init failed: $d"; fail=1; continue; }
  fi
  if want validate; then (cd "$ROOT/$d" && run "$TF_BIN" validate -no-color); fi
  if want test && [ -d "$ROOT/$d/tests" ]; then (cd "$ROOT/$d" && run "$TF_BIN" test -no-color); fi
  if want tflint && have tflint; then
    (cd "$ROOT/$d" && run tflint --config "$ROOT/.tflint.hcl" --no-color)
  fi
  if want docs && have terraform-docs; then
    (cd "$ROOT/$d" && run terraform-docs --config "$ROOT/.terraform-docs.yml" --output-check .)
  fi
done

if want checkov && have checkov; then
  run checkov --config-file "$ROOT/.checkov.yaml" --directory "$ROOT"
fi

exit $fail
