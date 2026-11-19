#!/usr/bin/env bash
# Regenerate SHA256SUMS for one tool directory:  scripts/update-checksums.sh ciphertrust-kmip-setup
set -eu
d=${1:?usage: update-checksums.sh <tool-directory>}
cd "$d"
find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name '.*' | sed 's#^\./##' | LC_ALL=C sort |
  while read -r f; do shasum -a 256 "$f"; done > SHA256SUMS
cat SHA256SUMS
