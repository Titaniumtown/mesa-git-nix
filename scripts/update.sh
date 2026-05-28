#!/usr/bin/env bash
# update.sh — Pin mesa-git-nix to the latest Mesa main branch commit.
#
# Custom updater (upstream.type = "custom" in update.json).
# The nix-packaging-standard updater doesn't handle Mesa's wraps.json
# regeneration, so this bespoke script manages the full update cycle.
#
# Contract: exit 0 = success / no update, exit 1 = update failed,
#           exit 2 = network or API error (retry next run).

set -euo pipefail

REPO_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT_FILE="${GITHUB_OUTPUT:-/tmp/update-outputs.env}"
: >"$OUTPUT_FILE"

output() { echo "$1=$2" >>"$OUTPUT_FILE"; }
log()   { echo "==> $*"; }
err()   { echo "::error::$*"; }
warn()  { echo "::warning::$*"; }

output "package_name" "mesa-git"
output "upstream_url" "$REPO_URL"

# --- Read current state ----------------------------------------------------
CURRENT_REV=$(jq -r '.rev' "$ROOT_DIR/version.json")
CURRENT_VERSION=$(jq -r '.version' "$ROOT_DIR/version.json")
output "old_version" "$CURRENT_REV"
log "Current version: $CURRENT_VERSION (rev ${CURRENT_REV:0:12})"

# --- Fetch latest commit ---------------------------------------------------
log "Fetching latest Mesa main commit..."
REV=$(git ls-remote "$REPO_URL" refs/heads/main | cut -f1) || {
  err "Network error fetching Mesa main"
  output "updated" "false"
  exit 2
}
if [ -z "$REV" ]; then
  err "Empty rev from ls-remote"
  output "updated" "false"
  exit 2
fi
log "Latest rev: ${REV:0:12}"
output "new_version" "$REV"

# --- Compare ---------------------------------------------------------------
if [ "$CURRENT_REV" = "$REV" ]; then
  log "Already up to date"
  output "updated" "false"
  exit 0
fi
log "Update found: ${CURRENT_REV:0:12} -> ${REV:0:12}"
output "updated" "true"

# --- Compute source hash ---------------------------------------------------
log "Computing source hash..."
ARCHIVE_URL="https://gitlab.freedesktop.org/mesa/mesa/-/archive/${REV}/mesa-${REV}.tar.gz"
HASH=$(nix store prefetch-file --unpack --json "$ARCHIVE_URL" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['hash'])") || {
  err "Failed to compute source hash"
  output "error_type" "hash-extraction"
  exit 1
}
DATE=$(date -u +%Y-%m-%d)
log "Hash: $HASH"
log "Date: $DATE"

# --- Extract Mesa version string -------------------------------------------
log "Extracting Mesa version string..."
VERSION_STRING="$CURRENT_VERSION"
VERSION_URL="https://gitlab.freedesktop.org/mesa/mesa/-/raw/${REV}/VERSION"
MESA_VERSION=$(curl -sfL "$VERSION_URL" | head -1 | tr -d '[:space:]') || true
if [ -z "$MESA_VERSION" ]; then
  MESON_URL="https://gitlab.freedesktop.org/mesa/mesa/-/raw/${REV}/meson.build"
  MESA_VERSION=$(curl -sfL "$MESON_URL" | head -10 \
    | grep -oP "version\s*:\s*'\K[^']+" | head -1) || true
fi
if [ -n "$MESA_VERSION" ]; then
  VERSION_STRING="${MESA_VERSION}"
  log "Mesa version: $VERSION_STRING"
fi

# --- Update version.json ---------------------------------------------------
log "Updating version.json..."
cat >"$ROOT_DIR/version.json" <<EOF
{
    "rev": "$REV",
    "hash": "$HASH",
    "version": "$VERSION_STRING",
    "date": "$DATE"
}
EOF

# --- Regenerate wraps.json (Rust crate dependencies) -----------------------
log "Fetching subprojects/*.wrap for Rust crate deps..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

(
  cd "$TMPDIR"
  git init -q
  git remote add origin "$REPO_URL"
  git fetch --depth 1 origin "$REV" 2>&1 | tail -1
  git checkout FETCH_HEAD -- subprojects/ 2>/dev/null
  log "Generating wraps.json..."
  python3 <<'PYEOF'
import configparser, pathlib, json, base64, binascii, urllib.parse
def to_sri(h):
    raw = binascii.unhexlify(h)
    b64 = base64.b64encode(raw).decode()
    return f"sha256-{b64}"
result = []
for f in sorted(pathlib.Path("subprojects").glob("*.wrap")):
    p = configparser.ConfigParser()
    p.read(f)
    if "wrap-file" not in p.sections():
        continue
    url = p.get("wrap-file", "source_url", fallback="")
    if "crates.io" not in url:
        continue
    parsed = urllib.parse.urlparse(url)
    parts = parsed.path.strip("/").split("/")
    name = parts[3]
    version = parts[4]
    h = p.get("wrap-file", "source_hash")
    result.append({"pname": name, "version": version, "hash": to_sri(h)})
with open("wraps_out.json", "w") as fd:
    json.dump(result, fd, indent=4)
    fd.write("\n")
PYEOF
)
cp "$TMPDIR/wraps_out.json" "$ROOT_DIR/wraps.json"


# --- Update README version table -------------------------------------------
log "Updating README.md..."
SHORT_REV="${REV:0:12}"
COMMIT_URL="https://gitlab.freedesktop.org/mesa/mesa/-/commit/${REV}"
 sed -i \
  -e "s@^| Rev     |.*@| Rev     | [\`${SHORT_REV}\`](${COMMIT_URL}) |@" \
  -e "s@^| Version |.*@| Version | \`${VERSION_STRING}\` |@" \
  -e "s@^| Date    |.*@| Date    | ${DATE} |@" \
  "$ROOT_DIR/README.md"

log "Step 1/2: nix flake check --no-build"
if ! nix flake check --no-build 2>&1; then
  err "Eval check failed"
  output "error_type" "eval-error"
  exit 1
fi
log "Step 2/2: nix eval version"
BUILT_VERSION=$(nix eval --raw .#mesa-git.version 2>&1) || {
  err "Version eval failed"
  output "error_type" "eval-error"
  exit 1
}
log "Built version: $BUILT_VERSION"
log "Update verified: ${CURRENT_REV:0:12} -> ${SHORT_REV}"
