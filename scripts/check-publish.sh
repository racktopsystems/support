#!/usr/bin/env bash
# Pre-publish scan. This repository is public: run this before every commit.
#   scripts/check-publish.sh            scan the whole working tree
# Exits non-zero if anything that must not be published is found.
# A line can be exempted with the marker  publish-check: allow  in a comment, but only
# for a false positive; say why in the same comment.
# This catches common mistakes. It does not replace reading your own diff.
set -u
cd "$(dirname "$0")/.."

PRIVATE_IP='\b(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}\b'
TICKETS='\b(QA|BSR|HUB|DOC|IIP|RAMP|SUP|ZD|PS|OPS)-[0-9]{2,}\b'
INTERNAL='atlassian\.net|onramp|bitbucket|stash\.|confluence|jira|zendesk|salesforce|racktopsystems\.com/internal|\.racktop\.local|\.internal\b'
SECRETS='AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY|Bearer [A-Za-z0-9._~+/=-]{20,}|(password|passwd|secret|token|api[_-]?key)[A-Za-z_]*[ ]*[:=][ ]*["'"'"']?[A-Za-z0-9/+_.-]{8,}'
SERIAL='\b(serial|S/N|SN)[ :#=]+[A-Z0-9-]{8,}'

fail=0
scan() { # label regex [-i]
  local out
  out=$(grep -rnEI ${3:-} --exclude-dir=.git --exclude=check-publish.sh --exclude=AGENTS.md --exclude=SHA256SUMS -e "$2" . | grep -v 'publish-check: allow')
  if [ -n "$out" ]; then
    printf '\n== %s ==\n%s\n' "$1" "$out"; fail=1
  fi
}
scan "Private IP addresses (use 192.0.2.x / 198.51.100.x / 203.0.113.x)" "$PRIVATE_IP"
scan "Internal ticket keys" "$TICKETS"
scan "Internal systems and URLs" "$INTERNAL" -i
scan "Possible secrets" "$SECRETS" -i
scan "Possible serial numbers" "$SERIAL" -i

# Commit messages: no co-author trailers from outside RackTop, no generated-with footers
msgs=$(git log --format='%h %B' 2>/dev/null | grep -iE 'co-authored-by:.*|generated with' | grep -viE 'co-authored-by:.*@racktopsystems\.com')
if [ -n "$msgs" ]; then printf '\n== Attribution lines in commit messages (remove them before pushing) ==\n%s\n' "$msgs"; fail=1; fi

# Files that must never be committed
bad=$(find . -path ./.git -prune -o -type f \( -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '.env*' -o -name '*.log' -o -name 'settings.env' \) -print)
[ -n "$bad" ] && { printf '\n== Key, credential or log files ==\n%s\n' "$bad"; fail=1; }

# Each tool directory needs a README and current checksums
for d in */; do
  case $d in scripts/|templates/|.github/) continue;; esac
  [ -f "$d/README.md" ] || { echo "Missing README.md in $d"; fail=1; }
  if [ -f "$d/SHA256SUMS" ]; then
    (cd "$d" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) || { echo "SHA256SUMS out of date in $d (run scripts/update-checksums.sh $d)"; fail=1; }
  else
    echo "Missing SHA256SUMS in $d"; fail=1
  fi
done

if [ $fail = 0 ]; then echo "check-publish: OK (now read your diff)"; else printf '\ncheck-publish: FAILED\n'; fi
exit $fail
