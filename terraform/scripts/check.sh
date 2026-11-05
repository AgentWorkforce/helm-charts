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
KNOWN=(fmt validate tflint test docs checkov)
[ ${#CHECKS[@]} -gt 0 ] || CHECKS=("${KNOWN[@]}")
for c in "${CHECKS[@]}"; do
  case " ${KNOWN[*]} " in *" $c "*) ;; *) echo "unknown check: $c (known: ${KNOWN[*]})" >&2; exit 2 ;; esac
done
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
# run [-C dir] cmd...: runs in the parent shell (no subshell), so a failure
# always reaches $fail.
run() {
  local dir="$ROOT"
  if [ "$1" = "-C" ]; then dir="$2"; shift 2; fi
  echo "+ (${dir#"$ROOT"/}) $*"
  if ! (cd "$dir" && "$@"); then echo "::error::failed in ${dir#"$ROOT"/}: $*"; fail=1; fi
}

if want fmt; then run "$TF_BIN" fmt -check -recursive -diff "$ROOT"; fi

for d in "${dirs[@]}"; do
  echo "== $d"
  if want validate || want test; then
    # Provider downloads (GitHub release assets) occasionally time out: retry.
    ok=0
    for attempt in 1 2 3 4; do
      if (cd "$ROOT/$d" && "$TF_BIN" init -backend=false -input=false -no-color >/dev/null); then ok=1; break; fi
      echo "init failed in $d (attempt $attempt), retrying"; sleep $((attempt * 15))
    done
    [ $ok = 1 ] || { echo "::error::init failed: $d"; fail=1; continue; }
  fi
  if want validate; then run -C "$ROOT/$d" "$TF_BIN" validate -no-color; fi
  if want test && [ -d "$ROOT/$d/tests" ]; then run -C "$ROOT/$d" "$TF_BIN" test -no-color; fi
  if want tflint && have tflint; then
    run -C "$ROOT/$d" tflint --config "$ROOT/.tflint.hcl" --no-color
  fi
  if want docs && have terraform-docs; then
    run -C "$ROOT/$d" terraform-docs --config "$ROOT/.terraform-docs.yml" --output-check .
  fi
done

if want checkov && have checkov; then
  run checkov --config-file "$ROOT/.checkov.yaml" --directory "$ROOT"
fi

exit $fail
