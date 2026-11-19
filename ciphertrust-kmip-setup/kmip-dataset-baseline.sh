#!/usr/bin/bash
#
# kmip-dataset-baseline.sh — verification helper for the CipherTrust KMIP setup.
# Read-only. Records every encrypted dataset's key status and mount state, plus a
# SHA-256 of one sample file per mounted dataset, then compares later runs to it.
#
#   kmip-dataset-baseline.sh record            take the baseline (pick sample files)
#   kmip-dataset-baseline.sh compare [label]   re-check the same datasets and files, report differences
#
# Files are kept in $BASE_DIR (default /var/racktop/kmip-baseline — persistent;
# do not use /root or /tmp, they are cleared at boot on BrickStor).

export PATH=/usr/racktop/sbin:/usr/bin:/usr/sbin:$PATH
BASE_DIR=${BASE_DIR:-/var/racktop/kmip-baseline}
mkdir -p "$BASE_DIR"; chmod 700 "$BASE_DIR"
SAMPLES=$BASE_DIR/samples.tsv

snapshot() { # name<TAB>keystatus<TAB>mounted<TAB>sample<TAB>sha256-prefix
  zfs get -H -o name,property,value -t filesystem,volume encryption,keystatus,mounted,mountpoint,type 2>/dev/null |
    awk -F'\t' '{v[$1,$2]=$3; n[$1]=1} END{for(d in n) if(v[d,"encryption"]!="off" && v[d,"encryption"]!="") printf "%s\t%s\t%s\t%s\t%s\n", d, v[d,"keystatus"], v[d,"mounted"], v[d,"mountpoint"], v[d,"type"]}' |
    sort | while IFS=$'\t' read -r d ks m mp t; do
      f=$(awk -F'\t' -v d="$d" '$1==d{print $2}' "$SAMPLES" 2>/dev/null)
      if [ "$1" = record ] && [ "$t" = filesystem ] && [ "$m" = yes ] && [ -d "$mp" ]; then
        f=$(find "$mp" -xdev -maxdepth 3 -type f -size +0 -size -65536k 2>/dev/null | head -1)
        [ -n "$f" ] && printf '%s\t%s\n' "$d" "$f" >> "$SAMPLES"
      fi
      h=-; [ -n "$f" ] && [ -r "$f" ] && h=$(digest -a sha256 "$f" 2>/dev/null | cut -c1-16)
      printf '%s\t%s\t%s\t%s\t%s\n' "$d" "$ks" "$m" "${f:--}" "${h:--}"
    done
}

case ${1:-} in
  record)
    : > "$SAMPLES"
    snapshot record > "$BASE_DIR/baseline.tsv"
    echo "Baseline: $(wc -l < "$BASE_DIR/baseline.tsv" | tr -d ' ') encrypted datasets, $(awk -F'\t' '$5!="-"' "$BASE_DIR/baseline.tsv" | wc -l | tr -d ' ') sample checksums. Saved in $BASE_DIR."
    awk -F'\t' '$2!="available"{print "  note: key not loaded at baseline (sealed vaults are normal): " $1}' "$BASE_DIR/baseline.tsv"
    ;;
  compare)
    [ -s "$BASE_DIR/baseline.tsv" ] || { echo "No baseline. Run: $0 record"; exit 2; }
    label=${2:-$(date -u +%Y%m%dT%H%M%SZ)}
    snapshot > "$BASE_DIR/check-$label.tsv"
    awk -F'\t' 'NR==FNR{b[$1]=$0; bk[$1]=$2; bm[$1]=$3; bh[$1]=$5; next}
      { seen[$1]=1
        if(!($1 in b)) { print "NEW       " $1 " keystatus=" $2; next }
        if($2!=bk[$1] || $3!=bm[$1]) { print "CHANGED   " $1 " keystatus " bk[$1] "->" $2 " mounted " bm[$1] "->" $3; bad++ }
        else if(bh[$1]!="-" && $5!=bh[$1]) { print "CHECKSUM  " $1 " " bh[$1] "->" $5; bad++ }
        else if(bh[$1]!="-") ok++ }
      END{ for(d in b) if(!(d in seen)) { print "MISSING   " d; bad++ }
           printf "Result: %d differences, %d checksums verified (%s)\n", bad, ok, (bad? "FAIL" : "PASS"); exit (bad>0) }' \
      "$BASE_DIR/baseline.tsv" "$BASE_DIR/check-$label.tsv"
    ;;
  *) sed -n '3,11p' "$0"; exit 2;;
esac
