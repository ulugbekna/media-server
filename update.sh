#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Update pinned image digests in docker-compose*.yml safely.
#
# What this does:
#   - For each `image: <ref>@sha256:...` line, finds the corresponding tag
#     from the `# tag: <ref>:tag` annotation directly above it.
#   - docker pulls that tag, inspects the upstream image's Created date.
#   - If the upstream image is older than the quarantine window (default
#     7 days), and its digest differs from the pinned one, proposes an
#     update — but the quarantine ensures you never roll forward to a
#     fresh image that hasn't had time to be reviewed by the community.
#
# Default is dry-run. Use --apply to actually rewrite the YAML files.
#
# Usage:
#   ./update.sh                       # report what would change (dry-run)
#   ./update.sh --apply               # rewrite the YAML in place, with .bak
#   ./update.sh --quarantine-days 30  # stricter quarantine window
#   ./update.sh --quarantine-days 0   # no quarantine (NOT recommended)
# -----------------------------------------------------------------------------
set -euo pipefail

APPLY=0
QUARANTINE_DAYS=7
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --quarantine-days) shift ;;  # consumed below
        --quarantine-days=*) QUARANTINE_DAYS="${arg#*=}" ;;
        -h|--help)
            sed -n '2,/^# ----/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
    esac
done
# Allow `--quarantine-days N` (separate token form)
while [ $# -gt 0 ]; do
    if [ "$1" = "--quarantine-days" ] && [ -n "${2:-}" ]; then
        QUARANTINE_DAYS="$2"; shift 2
    else
        shift
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

cyan()   { printf "\033[1;36m==> %s\033[0m\n" "$*"; }
green()  { printf "\033[1;32m    %s\033[0m\n" "$*"; }
yellow() { printf "\033[1;33m    %s\033[0m\n" "$*"; }
red()    { printf "\033[1;31m    %s\033[0m\n" "$*"; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    red "Docker is not installed or not running."; exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    red "python3 is required (used for ISO-8601 date math)."; exit 1
fi

cyan "Update mode: $([ "$APPLY" = "1" ] && echo APPLY || echo DRY-RUN) (quarantine ${QUARANTINE_DAYS} days)"

# Parse every (tag, current_digest, file, line_number) tuple from the compose files.
# Format relies on:
#     # tag: <ref>:<tag>
#     image: <ref>@sha256:<digest>
parse_pinned_images() {
    python3 - "$@" <<'PY'
import re, sys
pattern_tag    = re.compile(r'^\s*#\s*tag:\s*(\S+)\s*$')
pattern_image  = re.compile(r'^(\s*image:\s*)(\S+?)@sha256:([0-9a-f]{64})\s*$')
for path in sys.argv[1:]:
    pending_tag = None
    with open(path) as fh:
        for lineno, line in enumerate(fh, 1):
            m_tag = pattern_tag.match(line)
            if m_tag:
                pending_tag = m_tag.group(1)
                continue
            m_img = pattern_image.match(line)
            if m_img:
                if pending_tag is None:
                    print(f"WARN\t{path}:{lineno}\tno '# tag:' annotation above image line", file=sys.stderr)
                else:
                    repo = m_img.group(2)
                    digest = m_img.group(3)
                    print(f"{pending_tag}\t{repo}\t{digest}\t{path}\t{lineno}")
                pending_tag = None
            elif line.strip() and not line.lstrip().startswith('#'):
                # any non-comment, non-blank line resets the pending tag
                pending_tag = None
PY
}

COMPOSE_FILES=(docker-compose.yml)
[ -f docker-compose.vpn.yml ]      && COMPOSE_FILES+=(docker-compose.vpn.yml)
[ -f docker-compose.telegram.yml ] && COMPOSE_FILES+=(docker-compose.telegram.yml)

cyan "Scanning ${#COMPOSE_FILES[@]} compose files"
# Portable replacement for `mapfile` (bash 4+) — macOS ships bash 3.2.
PINNED_LIST=$(parse_pinned_images "${COMPOSE_FILES[@]}")
if [ -z "$PINNED_LIST" ]; then
    red "No pinned images found. Make sure each 'image: ...@sha256:...' line has"
    red "a '# tag: ...' comment directly above it."
    exit 1
fi
pinned_count=$(printf '%s\n' "$PINNED_LIST" | wc -l | tr -d ' ')
green "Found ${pinned_count} pinned image(s)"
echo ""

CHANGES_FILE=$(mktemp)
trap 'rm -f "$CHANGES_FILE"' EXIT

while IFS=$'\t' read -r tag repo current_digest file lineno; do
    [ -z "$tag" ] && continue
    short_old="${current_digest:0:12}"
    printf "==> %s\n" "$tag"
    printf "    file:  %s:%s\n" "$file" "$lineno"
    printf "    pinned digest:  sha256:%s...\n" "$short_old"

    if ! docker pull "$tag" >/dev/null 2>&1; then
        red "    pull failed; skipping"
        continue
    fi

    upstream_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$tag" 2>/dev/null | sed -E 's|.*@sha256:||')
    if [ -z "$upstream_digest" ]; then
        red "    couldn't read upstream digest; skipping"
        continue
    fi

    if [ "$upstream_digest" = "$current_digest" ]; then
        green "    up-to-date"
        echo ""
        continue
    fi

    created=$(docker inspect --format='{{.Created}}' "$tag")
    age_days=$(python3 - <<PY
import re, sys
from datetime import datetime, timezone
ts = "$created"
# Docker returns nanosecond precision (e.g. 2026-06-03T08:41:55.146558241+00:00);
# Python's fromisoformat only handles up to microseconds. Strip fractional seconds.
ts = re.sub(r"\.\d+", "", ts).replace("Z", "+00:00")
try:
    delta = datetime.now(timezone.utc) - datetime.fromisoformat(ts)
    print(delta.days)
except Exception as e:
    print("PARSE_ERROR:" + str(e), file=sys.stderr)
    print(-1)
PY
)
    if [ "$age_days" = "-1" ]; then
        red "    couldn't parse Created date '$created'; skipping"
        continue
    fi
    short_new="${upstream_digest:0:12}"
    printf "    upstream digest: sha256:%s...  (built %s, %d days ago)\n" "$short_new" "${created%T*}" "$age_days"

    if [ "$age_days" -lt "$QUARANTINE_DAYS" ]; then
        yellow "    SKIP — upstream image is younger than ${QUARANTINE_DAYS}-day quarantine"
        echo ""
        continue
    fi

    cyan "    READY TO UPDATE"
    printf "%s\t%s\t%s\t%s\n" "$file" "$current_digest" "$upstream_digest" "$tag" >> "$CHANGES_FILE"
    echo ""
done <<<"$PINNED_LIST"

CHANGE_COUNT=$(wc -l < "$CHANGES_FILE" | tr -d ' ')
if [ "$CHANGE_COUNT" = "0" ]; then
    cyan "Nothing to update."
    exit 0
fi

cyan "$CHANGE_COUNT image(s) ready to update"

if [ "$APPLY" = "0" ]; then
    yellow "Dry-run only. To apply: ./update.sh --apply"
    exit 0
fi

# --apply: rewrite each compose file in place, keeping a .bak.
# Get unique list of files via sort -u (portable; no associative arrays).
FILES_TO_BACKUP=$(cut -f1 "$CHANGES_FILE" | sort -u)

cyan "Backing up files"
while IFS= read -r f; do
    [ -z "$f" ] && continue
    cp "$f" "${f}.bak"
    green "  ${f} -> ${f}.bak"
done <<<"$FILES_TO_BACKUP"

cyan "Applying digest updates"
while IFS=$'\t' read -r file old_d new_d tag; do
    # Substitute via python to avoid sed -i portability headaches.
    python3 - "$file" "$old_d" "$new_d" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh: content = fh.read()
if old not in content:
    sys.stderr.write(f"WARN: old digest {old[:12]}... not found in {path}\n"); sys.exit(0)
content = content.replace(old, new)
with open(path, 'w') as fh: fh.write(content)
PY
    green "  ${tag}:  ${old_d:0:12}... -> ${new_d:0:12}...  in ${file}"
done < "$CHANGES_FILE"

cat <<EOF

==> Done.
    Files updated. Backups: *.bak

    Restart your stack with the new pinned digests:
      docker compose pull
      docker compose up -d

    If anything misbehaves, restore the old digests:
      for f in docker-compose*.yml.bak; do mv "\$f" "\${f%.bak}"; done

EOF
