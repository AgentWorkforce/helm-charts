#!/usr/bin/env bash
# Builds the development-preview customer handoff from HEAD, verifies both
# archive formats, extracts the tar.gz, and proves the extracted umbrella is
# installable on its own: helm dependency build + helm template with the
# shipped values-gcp.yaml. Also reports (as warnings) relative Markdown links
# in shipped documents that point outside the archive; the generated
# requirements doc links repository sources by design.
#
# Requires: git, python3, helm (with the cnpg/minio/open-telemetry
# repositories added, as in the lint workflow), tar, unzip.
set -euo pipefail

repo=$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)
work=$(mktemp -d "${TMPDIR:-/tmp}/customer-handoff-smoke.XXXXXX")
trap 'rm -rf "$work"' EXIT

bash "$repo/scripts/package-customer-handoff.sh" build \
  --mode preview --dev-allow-dirty --format both --output-dir "$work/out"
bash "$repo/scripts/package-customer-handoff.sh" verify "$work/out" --dev-allow-preview

rev12=$(git -C "$repo" rev-parse HEAD | cut -c1-12)
tarball="$work/out/agent-relay-customer-handoff-$rev12-DEVELOPMENT-PREVIEW.tar.gz"
zipball="$work/out/agent-relay-customer-handoff-$rev12-DEVELOPMENT-PREVIEW.zip"
test -f "$tarball" && test -f "$zipball"

mkdir -p "$work/tar" "$work/zip"
tar -xzf "$tarball" -C "$work/tar"
unzip -q "$zipball" -d "$work/zip"
diff -r "$work/tar" "$work/zip" >/dev/null \
  || { echo "error: tar.gz and zip payloads differ" >&2; exit 1; }
root="$work/tar/agent-relay-customer-handoff"

# The umbrella resolves every file:// dependency inside the archive.
helm dependency build "$root/charts/sessions-pipeline" >/dev/null
helm dependency build "$root/charts/agent-relay" >/dev/null
helm template agent-relay "$root/charts/agent-relay" \
  --namespace agent-relay -f "$root/charts/agent-relay/values-gcp.yaml" >"$work/rendered.yaml"
test -s "$work/rendered.yaml"

# The packaged skill finds the packaged layout.
(
  cd "$root"
  unset HANDOFF_ROOT
  # shellcheck disable=SC1091
  . .agents/skills/setting-up-self-hosted-agent-relay-gcp/scripts/resolve-layout.sh
  resolve_agent_relay_layout
  test "$AGENT_RELAY_BASE_VALUES_FILE" -ef "$root/charts/agent-relay/values-gcp.yaml"
)

# Relative links in shipped Markdown that do not resolve inside the archive.
python3 -I - "$root" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
link = re.compile(r"\]\(([^)\s]+)\)")
broken = []
for doc in sorted(root.rglob("*.md")):
    for target in link.findall(doc.read_text(encoding="utf-8")):
        if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
            continue
        path = target.split("#", 1)[0]
        if path and not (doc.parent / path).resolve().exists():
            broken.append(f"{doc.relative_to(root)}: {target}")
for item in broken:
    print(f"::warning::shipped Markdown links outside the handoff: {item}")
PY

echo "customer handoff smoke: OK ($(find "$root" -type f | wc -l | tr -d ' ') files)"
