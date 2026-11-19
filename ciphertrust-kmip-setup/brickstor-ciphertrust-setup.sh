#!/usr/bin/bash
#
# brickstor-ciphertrust-setup.sh — guided setup of Thales CipherTrust Manager as the
# KMIP key manager for a BrickStor SP appliance.
#
# Copyright 2026 RackTop Systems, Inc.
#
# Run on the BrickStor appliance as root (or with sudo). Every step can be run on its
# own and re-run safely. Nothing that changes the key manager happens without an
# explicit confirmation, and every change is backed up first.
#
#   ./brickstor-ciphertrust-setup.sh run            guided, all steps in order
#   ./brickstor-ciphertrust-setup.sh help           list of steps and options
#
# Secrets (CipherTrust admin password, key archive passwords) are prompted for and
# never written to disk or to the transcript.

set -o pipefail
umask 077

VERSION="1.0"
export PATH=/usr/racktop/sbin:/usr/bin:/usr/sbin:/sbin:/bin:$PATH

STATE_DIR=${STATE_DIR:-/var/racktop/ciphertrust-setup}   # persistent: / (and /root) is a ramdisk on BrickStor
CERT_DIR=${CERT_DIR:-/etc/racktop/keymgrd/ciphertrust}
KCONF=/etc/racktop/keymgrd/keymgrd.conf
KLOG=/var/log/keymgrd/keymgrd.log
KFMRI=svc:/racktop/keymgrd:default
SETTINGS=$STATE_DIR/settings.env
TRANSCRIPT=$STATE_DIR/transcript.log
YES=${YES:-0}

# ---------------------------------------------------------------- output helpers
if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; else B=; R=; G=; Y=; N=; fi
log()  { mkdir -p "$STATE_DIR"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$TRANSCRIPT"; }
say()  { printf '%s\n' "$*"; log "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; log "== $* =="; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; log "OK   $*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; log "WARN $*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; log "FAIL $*"; }
KM_CHANGED=0 # set once keymgrd.conf has been rewritten in this run
die()  {
  bad "$*"
  if [ "$KM_CHANGED" = 1 ]; then
    printf '\n%sStopped.%s The key manager configuration WAS changed in this run (backup in %s).\n' "$R" "$N" "$STATE_DIR"
    printf 'Unlocked datasets and drives keep working. To return to the previous key manager: %s rollback\nTranscript: %s\n' "$0" "$TRANSCRIPT"
  else
    printf '\n%sStopped.%s No further changes were made after the last step shown. Transcript: %s\n' "$R" "$N" "$TRANSCRIPT"
  fi
  exit 1
}
confirm() { # confirm "question" — returns 0 on yes
  [ "$YES" = 1 ] && { log "auto-yes: $1"; return 0; }
  [ -t 0 ] || die "Confirmation needed with no terminal: $1 (run interactively, or set YES=1)."
  local a; read -r -p "  $1 [y/N] " a; log "Q: $1 -> ${a:-N}"; [[ $a =~ ^[Yy] ]]
}
ask() { # ask VAR "prompt" [default]
  local v cur=${!1}; local def=${cur:-$3}
  if [ -n "$def" ] && [ "$YES" = 1 ]; then printf -v "$1" '%s' "$def"; return; fi
  [ -t 0 ] || [ -n "$def" ] || die "Input needed with no terminal: $2 (set $1 in the environment, or run interactively)."
  [ -t 0 ] || { printf -v "$1" '%s' "$def"; return; }
  read -r -p "  $2${def:+ [$def]}: " v; printf -v "$1" '%s' "${v:-$def}"; log "A: $2 = ${!1}"
}
need_root() { [ "$(id -u)" = 0 ] || die "Run as root (for example: sudo $0 $*)."; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%S; }

# ---------------------------------------------------------------- settings
save_settings() {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  {
    for v in KMIP_HOST KMIP_ADDR KMIP_PORT ZONE CN CM_URL CM_HOST CM_ADDR CM_CA \
             PROFILE CLIENT_NAME HA_MODE; do printf '%s=%q\n' "$v" "${!v}"; done
  } > "$SETTINGS"
}
load_settings() { # saved settings fill in only what is not already set (environment wins)
  if [ -f "$SETTINGS" ]; then
    local line name
    while IFS= read -r line; do
      name=${line%%=*}; [[ $name =~ ^[A-Z_]+$ ]] || continue
      [ -z "${!name}" ] && eval "$line"
    done < "$SETTINGS"
  fi
  KMIP_PORT=${KMIP_PORT:-5696}
}

# ---------------------------------------------------------------- appliance facts
conf_get() { sed -n "s/^$1 = \"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$KCONF" | head -1; }
km_type()  { conf_get Type; }
keys_json() { # prints the key list only when keyadm returns a JSON array (it can return other output mid-import)
  local j; j=$(keyadm -j keys list 2>/dev/null) && printf '%s' "$j" | jq -e 'type=="array"' >/dev/null 2>&1 && printf '%s' "$j"
}
have_keyadm() { command -v keyadm >/dev/null 2>&1; }
enc_snapshot() { # name<TAB>keystatus<TAB>mounted for every encrypted filesystem/volume
  zfs get -H -o name,property,value -t filesystem,volume encryption,keystatus,mounted 2>/dev/null |
    awk -F'\t' '{v[$1,$2]=$3; n[$1]=1} END{for(d in n) if(v[d,"encryption"]!="off" && v[d,"encryption"]!="") printf "%s\t%s\t%s\n", d, v[d,"keystatus"], v[d,"mounted"]}' | sort
}
sed_enrolled_ids() { secadm -j list all 2>/dev/null | jq -r '.Drives[]? | select(.KeyStoreId != "" and .KeyStoreId != null) | .Id'; }
svc_state() { svcs -H -o state "$KFMRI" 2>/dev/null; }
log_since() { # log_since "message" "YYYY-MM-DDTHH:MM:SS" — prints matching keymgrd log lines at or after time
  awk -v t="$2" -v m="$1" -F'"time":"' 'index($0,m){ if (substr($2,1,19) >= t) print }' "$KLOG" 2>/dev/null
}

# ---------------------------------------------------------------- TLS helpers
peer_cert() { # peer_cert host port [sni] -> PEM of leaf
  echo | openssl s_client -connect "$1:$2" ${3:+-servername "$3"} 2>/dev/null | openssl x509 2>/dev/null
}
cert_names() { openssl x509 -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS:\(.*\)/\1/p' | tr -d ' '; }
cert_names_compat() { openssl x509 -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1 | tr ',' '\n' | sed -n 's/.*DNS:\(.*\)/\1/p' | tr -d ' '; }
resolves() { getent hosts "$1" 2>/dev/null | awk '{print $1; exit}'; }

# ---------------------------------------------------------------- CipherTrust API
CM_TOKEN=""
cm_curl() { # cm_curl METHOD PATH [JSON]  -> body; sets CM_HTTP
  local out; out=$(mktemp); local args=(-sS -m 60 -o "$out" -w '%{http_code}' -X "$1" --cacert "$CM_CA")
  [ -n "$CM_ADDR" ] && [ -n "$CM_HOST" ] && args+=(--resolve "$CM_HOST:443:$CM_ADDR")
  args+=(-H 'Content-Type: application/json')
  [ -n "$CM_TOKEN" ] && args+=(-H "Authorization: Bearer $CM_TOKEN")
  [ -n "$3" ] && args+=(--data-binary @-)
  printf '%s' "$3" | curl "${args[@]}" "https://$CM_HOST/api$2" > "$STATE_DIR/.cm_http"
  cat "$out"; rm -f "$out"
}
cm_code() { cat "$STATE_DIR/.cm_http" 2>/dev/null; }   # HTTP status of the last API call (survives subshells)
cm_ok() { [[ $(cm_code) =~ ^2 ]]; }

cm_trust() { # establish a verified TLS path to the CipherTrust web/API interface
  hdr "CipherTrust API connection"
  ask CM_ADDR "CipherTrust Manager address (IP or hostname of the web interface)" "$CM_ADDR"
  local pem; pem=$(peer_cert "$CM_ADDR" 443) || true
  [ -n "$pem" ] || die "No TLS answer from $CM_ADDR:443. Check network access from this appliance."
  local names; names=$(printf '%s\n' "$pem" | cert_names); [ -n "$names" ] || names=$(printf '%s\n' "$pem" | cert_names_compat)
  say "  Web certificate: $(printf '%s\n' "$pem" | openssl x509 -noout -subject | sed 's/subject=//')"
  say "  Issued by:       $(printf '%s\n' "$pem" | openssl x509 -noout -issuer | sed 's/issuer=//')"
  say "  Names:           ${names:-none}"
  CM_HOST=${CM_HOST:-$(printf '%s\n' "$names" | head -1)}
  [ -n "$CM_HOST" ] || CM_HOST=$CM_ADDR
  if [ -z "$CM_CA" ] || [ ! -s "$CM_CA" ]; then
    CM_CA=$STATE_DIR/ciphertrust-web-ca.pem
    # take the last certificate the server presents (its issuing CA) and ask the admin to confirm it
    local nc; nc=$(echo | openssl s_client -connect "$CM_ADDR:443" -showcerts 2>/dev/null |
      awk -v d="$STATE_DIR" '/BEGIN CERT/{c++; f=d "/cm-chain-" c ".pem"} f{print > f} /END CERT/{close(f); f=""} END{print c+0}')
    if [ -n "$CM_CA_SRC" ] && [ -s "$CM_CA_SRC" ]; then cp "$CM_CA_SRC" "$CM_CA"
    elif [ "${nc:-0}" -gt 1 ]; then cp "$STATE_DIR/cm-chain-$nc.pem" "$CM_CA"   # last certificate sent = issuing CA
    else
      warn "The server did not send its CA certificate. Set CM_CA_SRC to the CipherTrust root CA file to use it,"
      warn "or confirm below to pin the certificate this server presents (its name is still checked)."
      printf '%s\n' "$pem" > "$CM_CA"
    fi
    rm -f "$STATE_DIR"/cm-chain-*.pem
    say "  Trust anchor:    $(openssl x509 -in "$CM_CA" -noout -subject | sed 's/subject=//')"
    say "  SHA-256:         $(openssl x509 -in "$CM_CA" -noout -fingerprint -sha256 | cut -d= -f2)"
    confirm "Compare this fingerprint with the CA in the CipherTrust console. Trust it?" || die "CA not trusted."
  fi
  CM_URL="https://$CM_HOST"
  local code; code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' --cacert "$CM_CA" ${CM_ADDR:+--resolve "$CM_HOST:443:$CM_ADDR"} "$CM_URL/api/v1/system/info" 2>&1)
  [[ $code =~ ^[0-9]{3}$ ]] || die "TLS verification of $CM_HOST failed with the trusted CA: $code"
  ok "Verified TLS connection to $CM_HOST ($CM_ADDR)"
  save_settings
}

cm_login() {
  local user pw body
  ask CM_USER "CipherTrust administrator user" "${CM_USER:-admin}"
  if [ -n "$CM_PASSWORD_FILE" ]; then   # automation: password read from a root-only file, never logged
    [ -r "$CM_PASSWORD_FILE" ] || die "Cannot read CM_PASSWORD_FILE."
    pw=$(head -1 "$CM_PASSWORD_FILE")
  else
    [ -t 0 ] || die "CipherTrust password needed with no terminal (run interactively, or set CM_PASSWORD_FILE)."
    read -r -s -p "  CipherTrust password for $CM_USER: " pw; echo
  fi
  body=$(jq -n --arg u "$CM_USER" --arg p "$pw" '{grant_type:"password",username:$u,password:$p}')
  pw=""
  CM_TOKEN=$(cm_curl POST /v1/auth/tokens/ "$body" | jq -r '.jwt // .access_token // empty')
  body=""
  [ -n "$CM_TOKEN" ] || die "CipherTrust login failed (HTTP $(cm_code))."
  ok "Logged in to CipherTrust as $CM_USER"
}

# ================================================================= steps
step_preflight() {
  hdr "Preflight"
  need_root
  local v; v=$(uname -v); ok "BrickStorOS $v on $(hostname)"
  for t in jq curl openssl zfs secadm bsradm bsrzfs; do command -v $t >/dev/null || die "Required tool missing: $t"; done
  have_keyadm && ok "keyadm available (key inventory checks enabled)" || warn "keyadm not found on this build: key counts will be checked from the log only"
  [ "$(svc_state)" = online ] && ok "Key manager service online" || die "Key manager service is $(svc_state). Fix this before continuing."
  local t; t=$(km_type); ok "Current key manager type: $t"
  local zone; zone=$(conf_get KmipZone)
  if [ "$t" != "Local" ]; then
    warn "This appliance already uses '$t' (zone '${zone:-none}'). Re-running is supported; the zone will not be changed."
  fi
  if have_keyadm; then
    local n; n=$(keys_json | jq 'length' 2>/dev/null); ok "Keys currently held: ${n:-unknown}"
  fi
  local enc; enc=$(enc_snapshot); local ne; ne=$(printf '%s' "$enc" | grep -c . )
  local nu; nu=$(printf '%s\n' "$enc" | awk -F'\t' '$2!="available"' | grep -c .)
  ok "Encrypted datasets: $ne (keys not loaded now: $nu — sealed vaults are normally in this group)"
  local sed; sed=$(sed_enrolled_ids | grep -c .); ok "SED drives enrolled: $sed"
  if hiavadm info dump >/dev/null 2>&1 && hiavadm info dump 2>/dev/null | grep -qi '"node'; then
    warn "This appliance appears to be in an HA cluster. Both nodes must use the same client identity: run 'prepare' and 'register' on one node, then 'bundle-export' there and 'bundle-import' on the other. Switch both nodes in the same maintenance window."
    HA_MODE=${HA_MODE:-cluster}
  else HA_MODE=${HA_MODE:-single}; fi
  local skew; skew=$(date -u +%s); ok "Clock (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ) — make sure NTP is in sync with CipherTrust"
  save_settings
}

step_server() {
  hdr "Key server address"
  load_settings
  ask KMIP_ADDR "CipherTrust KMIP address (IP or hostname)" "${KMIP_ADDR:-$CM_ADDR}"
  ask KMIP_PORT "KMIP port" "${KMIP_PORT:-5696}"
  local pem; pem=$(peer_cert "$KMIP_ADDR" "$KMIP_PORT")
  [ -n "$pem" ] || die "No TLS answer from $KMIP_ADDR:$KMIP_PORT. Check that the KMIP interface is enabled and port $KMIP_PORT is open from this appliance."
  ok "KMIP interface answers on $KMIP_ADDR:$KMIP_PORT"
  local names; names=$(printf '%s\n' "$pem" | cert_names); [ -n "$names" ] || names=$(printf '%s\n' "$pem" | cert_names_compat)
  say "  KMIP certificate names: ${names:-none}"
  if [ -z "$KMIP_HOST" ]; then
    if printf '%s\n' "$names" | grep -qx "$KMIP_ADDR"; then KMIP_HOST=$KMIP_ADDR; else KMIP_HOST=$(printf '%s\n' "$names" | head -1); fi
  fi
  ask KMIP_HOST "Hostname to use (must be one of the certificate names)" "$KMIP_HOST"
  printf '%s\n' "$names" | grep -qx "$KMIP_HOST" || die "$KMIP_HOST is not in the KMIP server certificate. Use one of: $names"
  local ip; ip=$(resolves "$KMIP_HOST")
  if [ -z "$ip" ]; then
    warn "$KMIP_HOST does not resolve on this appliance."
    if [[ $KMIP_ADDR =~ ^[0-9.]+$ ]] && confirm "Add a persistent hosts entry $KMIP_ADDR $KMIP_HOST (bsradm hosts add)?"; then
      bsradm hosts add --comment "CipherTrust KMIP server" "$KMIP_ADDR" "$KMIP_HOST" >/dev/null || die "bsradm hosts add failed."
      ip=$(resolves "$KMIP_HOST"); [ -n "$ip" ] || die "Entry added but $KMIP_HOST still does not resolve."
      ok "Hosts entry added: $KMIP_HOST -> $ip (survives reboot)"
    else die "Add a DNS record or hosts entry for $KMIP_HOST and re-run."; fi
  else ok "$KMIP_HOST resolves to $ip"; fi
  local zone; zone=$(conf_get KmipZone)
  if [ -n "$zone" ] && [ "$(km_type)" != Local ]; then   # only an active KMIP zone holds keys that must stay findable
    ZONE=$zone; ok "Keeping existing KMIP zone '$ZONE' (changing it would hide existing keys)"
  else
    [ -n "$zone" ] && warn "keymgrd.conf has a leftover zone '$zone' from an earlier setup; it is not in use (key manager is Local)."
    ask ZONE "KMIP zone (namespace for this appliance's keys; keep it stable)" "${ZONE:-$(hostname)}"
  fi
  [ -n "$ZONE" ] || die "Zone must not be empty."
  save_settings
}

step_prepare() {
  hdr "Client key and certificate request"
  need_root; load_settings
  ask CN "Certificate common name (also the CipherTrust user name)" "${CN:-$(hostname)-kmip}"
  [[ $CN =~ ^[A-Za-z0-9._-]{3,64}$ ]] || die "Use 3-64 letters, digits, dot, dash or underscore for the common name."
  mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
  if [ -s "$CERT_DIR/clientkey.pem" ]; then
    ok "Client key already exists in $CERT_DIR (kept)"
  else
    openssl genrsa -out "$CERT_DIR/clientkey.pem" 3072 2>/dev/null || die "Key generation failed."
    chmod 600 "$CERT_DIR/clientkey.pem"; ok "Created client key (RSA 3072). It never leaves this appliance."
  fi
  openssl req -new -key "$CERT_DIR/clientkey.pem" -subj "/CN=$CN" -out "$CERT_DIR/client.csr" 2>/dev/null || die "CSR creation failed."
  openssl req -in "$CERT_DIR/client.csr" -noout -verify 2>&1 | grep -q 'verify OK' || die "CSR does not verify."
  ok "Certificate request: $CERT_DIR/client.csr (CN=$CN)"
  save_settings
}

step_register() {
  hdr "Register with CipherTrust"
  need_root; load_settings
  [ -s "$CERT_DIR/client.csr" ] || die "No CSR yet. Run the 'prepare' step first."
  say "  Automatic registration uses the CipherTrust API with an administrator login to:"
  say "    create user '$CN' in Key Users, a client profile with this CSR, a one-time"
  say "    registration token, and register client '${CLIENT_NAME:-$CN}'. It then installs the signed"
  say "    certificate and the KMIP server CA on this appliance."
  if ! confirm "Register automatically through the CipherTrust API?"; then manual_register; return; fi
  cm_trust; cm_login
  local r
  # KMIP interface and license
  r=$(cm_curl GET /v1/configs/interfaces/)
  local mode; mode=$(printf '%s' "$r" | jq -r '.resources[]? | select(.name=="kmip") | "\(.mode) \(.port) \(.enabled)"')
  [ -n "$mode" ] || die "No KMIP interface found on CipherTrust."
  set -- $mode
  [ "$3" = true ] || die "The CipherTrust KMIP interface is disabled."
  [ "$2" = "$KMIP_PORT" ] || warn "CipherTrust KMIP interface listens on $2, setup uses $KMIP_PORT."
  case $1 in tls-cert-pw-opt|tls-cert-and-pw|tls-pw-opt) ok "KMIP interface mode $1";;
             *) warn "KMIP interface mode is '$1'. RackTop tested 'tls-cert-pw-opt'.";; esac
  local caid; caid=$(printf '%s' "$r" | jq -r '.resources[]? | select(.name=="kmip") | (.trusted_cas.local[0] // .auto_gen_ca_id // "") | split(":") | last')
  [ -n "$caid" ] || die "Cannot find the local CA trusted by the KMIP interface."
  r=$(cm_curl GET /v1/licensing/features/)
  if printf '%s' "$r" | jq -e '[.resources[]? | select((.name // "" | ascii_upcase)=="KMIP")] | length>0' >/dev/null; then
    printf '%s' "$r" | jq -e '[.resources[]? | select((.name // "" | ascii_upcase)=="KMIP") | select((.status // .state // "") | test("active";"i"))] | length>0' >/dev/null \
      && ok "KMIP license active" || warn "KMIP license feature found but not reported active. Check Admin Settings > Licensing."
  else warn "Could not confirm the KMIP license from the API. Check Admin Settings > Licensing."; fi
  # user
  r=$(cm_curl GET "/v1/usermgmt/users/?limit=1000")
  local uid; uid=$(printf '%s' "$r" | jq -r --arg u "$CN" '.resources[]? | select(.username==$u) | .user_id' | head -1)
  if [ -n "$uid" ]; then ok "CipherTrust user $CN exists (reused)"
  else
    local upw; upw="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)aA1!"
    r=$(cm_curl POST /v1/usermgmt/users/ "$(jq -n --arg u "$CN" --arg p "$upw" '{username:$u,name:$u,password:$p,connection:"local_account",login_flags:{prevent_ui_login:true}}')")
    upw=""
    cm_ok || die "Creating user $CN failed (HTTP $(cm_code)): $(printf '%s' "$r" | jq -r '.message // .codeDesc // empty')"
    uid=$(printf '%s' "$r" | jq -r '.user_id'); ok "Created CipherTrust user $CN (console login disabled; certificate authentication only)"
  fi
  r=$(cm_curl POST "/v1/usermgmt/groups/Key%20Users/users/$(printf '%s' "$uid" | jq -sRr @uri)" '{}')
  cm_ok || [ "$(cm_code)" = 409 ] || die "Adding $CN to Key Users failed (HTTP $(cm_code))."
  ok "$CN is in Key Users"
  # client: CipherTrust allows one KMIP client per certificate name, so an old client with this name blocks registration
  CLIENT_NAME=${CLIENT_NAME:-$CN}
  r=$(cm_curl GET "/v1/kmip/kmip-clients?limit=1000")
  if printf '%s' "$r" | jq -e --arg n "$CLIENT_NAME" --arg c "$CN" '.resources[]? | select(.name==$n or .name==$c)' >/dev/null; then
    die "A KMIP client named '$CLIENT_NAME' already exists in CipherTrust (left by an earlier setup), and CipherTrust allows one client per certificate name.
    - If no appliance uses it any more: delete it in the CipherTrust console (KMIP > Registered Clients), then run '$0 register' again.
    - Otherwise use a different name: CN=<new-name> $0 prepare   and then   $0 register"
  fi
  # profile
  PROFILE=${PROFILE:-$CN-profile}
  r=$(cm_curl GET /v1/kmip/kmip-profiles)
  if printf '%s' "$r" | jq -e --arg p "$PROFILE" '.resources[]? | select(.name==$p)' >/dev/null; then
    PROFILE="${PROFILE%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}-$(date +%Y%m%d%H%M%S)"; warn "Profile name in use; using $PROFILE"
  fi
  r=$(cm_curl POST /v1/kmip/kmip-profiles "$(jq -n --arg n "$PROFILE" --rawfile csr "$CERT_DIR/client.csr" '{name:$n,do_not_modify_subject_dn:true,cert_duration:365,properties:{cert_user_field:"CN",csr:$csr}}')")
  cm_ok || die "Creating client profile failed (HTTP $(cm_code)): $(printf '%s' "$r" | jq -r '.message // empty')"
  ok "Client profile $PROFILE (username from certificate CN, 365-day certificate)"
  # token + client
  r=$(cm_curl POST /v1/kmip/regtokens/ "$(jq -n --arg c "$caid" --arg p "$PROFILE" --arg n "$CLIENT_NAME" '{ca_id:$c,lifetime:"1h",max_clients:1,profile_name:$p,name_prefix:$n}')")
  local tok; tok=$(printf '%s' "$r" | jq -r '.token // empty'); r=""
  [ -n "$tok" ] || die "Creating a registration token failed (HTTP $(cm_code))."
  r=$(cm_curl POST /v1/kmip/kmip-clients "$(jq -n --arg n "$CLIENT_NAME" --arg t "$tok" '{name:$n,reg_token:$t}')"); tok=""
  cm_ok || die "Registering client failed (HTTP $(cm_code)): $(printf '%s' "$r" | jq -r '.message // empty')"
  printf '%s' "$r" | jq -r '.cert // .signed_csr // empty' > "$CERT_DIR/clientcert.pem"
  [ -s "$CERT_DIR/clientcert.pem" ] || die "CipherTrust did not return a client certificate."
  ok "Registered KMIP client $CLIENT_NAME and saved the signed certificate"
  # server CA: the CA that issued the KMIP interface certificate
  local scaid; scaid=$(cm_curl GET /v1/configs/interfaces/ | jq -r '.resources[]? | select(.name=="kmip") | (.auto_gen_ca_id // .trusted_cas.local[0] // "") | split(":") | last')
  cm_curl GET "/v1/ca/local-cas/$scaid" | jq -r '.cert // empty' > "$CERT_DIR/certauth.pem"
  [ -s "$CERT_DIR/certauth.pem" ] || die "Could not download the KMIP server CA certificate."
  ok "Saved KMIP server CA: $(openssl x509 -in "$CERT_DIR/certauth.pem" -noout -subject | sed 's/subject=//')"
  CM_TOKEN=""
  chmod 600 "$CERT_DIR"/*.pem
  save_settings
}

manual_register() {
  hdr "Manual registration in the CipherTrust console"
  cat <<EOF
  1. Admin Settings > Users: create user '$CN', add it to Key Users.
  2. KMIP > Client Profile: add a profile, Bring your own key, paste this CSR,
     Username Location in Certificate = CN, keep the subject DN.
  3. KMIP > Registration Token: create a token for that profile (client capacity 1).
  4. KMIP > Registered Clients: add a client with the token. Save the certificate.
  5. Save the CA certificate that issued the KMIP server certificate
     (CA > Local > the CA used by the KMIP interface).

----- CSR ($CERT_DIR/client.csr) -----
$(cat "$CERT_DIR/client.csr")
--------------------------------------
EOF
  local c a
  ask c "Path to the signed client certificate (PEM)" ""; [ -s "$c" ] || die "File not found: $c"
  ask a "Path to the KMIP server CA certificate (PEM)" ""; [ -s "$a" ] || die "File not found: $a"
  cp "$c" "$CERT_DIR/clientcert.pem"; cp "$a" "$CERT_DIR/certauth.pem"; chmod 600 "$CERT_DIR"/*.pem
  ok "Installed client certificate and server CA"
}

step_verify() {
  hdr "Verify certificates and mutual TLS"
  need_root; load_settings
  local d=$CERT_DIR f
  for f in clientkey.pem clientcert.pem certauth.pem; do [ -s "$d/$f" ] || die "Missing $d/$f"; done
  local mk mc; mk=$(openssl rsa -in "$d/clientkey.pem" -noout -modulus 2>/dev/null | openssl md5); mc=$(openssl x509 -in "$d/clientcert.pem" -noout -modulus 2>/dev/null | openssl md5)
  [ -n "$mk" ] && [ "$mk" = "$mc" ] && ok "Client certificate matches the client key" || die "Client certificate does not match the client key."
  openssl x509 -in "$d/clientcert.pem" -noout -checkend 2592000 >/dev/null && ok "Client certificate valid for at least 30 more days ($(openssl x509 -in "$d/clientcert.pem" -noout -enddate | cut -d= -f2))" \
    || warn "Client certificate expires within 30 days: $(openssl x509 -in "$d/clientcert.pem" -noout -enddate | cut -d= -f2)"
  local subj; subj=$(openssl x509 -in "$d/clientcert.pem" -noout -subject); [[ $subj == *"CN = $CN"* || $subj == *"CN=$CN"* ]] && ok "Certificate CN is $CN" || warn "Certificate subject is '$subj', expected CN=$CN"
  [ -n "$KMIP_HOST" ] || die "Key server address not set. Run the 'server' step first."
  local out; out=$(echo | openssl s_client -connect "$KMIP_HOST:$KMIP_PORT" -CAfile "$d/certauth.pem" \
        -cert "$d/clientcert.pem" -key "$d/clientkey.pem" -verify_hostname "$KMIP_HOST" -verify_return_error 2>&1)
  if printf '%s' "$out" | grep -q 'Verify return code: 0 (ok)'; then
    ok "Mutual TLS to $KMIP_HOST:$KMIP_PORT: server certificate trusted and name matches"
  else
    bad "TLS check failed:"; printf '%s\n' "$out" | grep -E 'verify error|Verify return|alert|errno|refused' | head -5 | sed 's/^/      /'
    die "Fix the certificate, CA or hostname problem above, then re-run 'verify'."
  fi
  local noc; noc=$(echo | openssl s_client -connect "$KMIP_HOST:$KMIP_PORT" -CAfile "$d/certauth.pem" -verify_hostname "$KMIP_HOST" 2>&1)
  printf '%s' "$noc" | grep -qiE 'alert|handshake failure|certificate required' && ok "Server rejects connections without a client certificate (as configured)" \
    || say "  (info) A TLS session without a client certificate was not refused at handshake; CipherTrust may still refuse it per request."
  chmod 700 "$d"; chmod 600 "$d"/*.pem
}

snapshot_before() {
  local tag=$1
  have_keyadm && keys_json > "$STATE_DIR/keys-$tag.json"
  enc_snapshot > "$STATE_DIR/datasets-$tag.tsv"
  secadm -j list all > "$STATE_DIR/sed-$tag.json" 2>/dev/null
}

restart_km() { # restart keymgrd, recover from SMF maintenance, wait for the expected type
  local want=$1 t0; t0=$(now_utc)
  svcadm restart "$KFMRI"
  local i st
  for i in $(seq 1 60); do
    sleep 2; st=$(svc_state)
    case $st in
      online) break;;
      maintenance) warn "Key manager went to maintenance during restart (known issue); clearing it"; svcadm clear "$KFMRI";;
    esac
  done
  [ "$(svc_state)" = online ] || die "Key manager service is '$(svc_state)' after restart. See: svcs -xv $KFMRI"
  # 23.9+ logs "Type":"KMIP" as a field; 23.8 and earlier log "Set up key manager (type KMIP)."
  local pat="\"Type\":\"$want\"|\\(type $want\\)"
  for i in $(seq 1 15); do log_since "Set up key manager" "$t0" | grep -Eq "$pat" && break; sleep 2; done
  log_since "Set up key manager" "$t0" | grep -Eq "$pat" || die "Key manager did not start with type $want. Check $KLOG"
  ok "Key manager restarted with type $want"
  RESTARTED_AT=$t0
}

kmip_errors_since() { # key retrieval / connection failures logged since time $1 (the Discover Versions warning alone is not counted)
  awk -v t="$1" -F'"time":"' 'substr($2,1,19) >= t' "$KLOG" 2>/dev/null |
    grep -E 'read header: EOF|broken pipe|Get keys failed|Error searching keys|connection refused|i/o timeout|bad certificate|x509:' |
    grep -v '42005c not supported'
}

check_kmip_traffic() { # after switching to KMIP: watch the log briefly for real key-server failures and offer rollback
  say "  Watching the key manager log for 45 seconds for KMIP connection or key retrieval errors..."
  sleep 45
  local e; e=$(kmip_errors_since "$RESTARTED_AT")
  if [ -z "$e" ]; then ok "No KMIP connection or key retrieval errors since the restart"; return 0; fi
  bad "The key manager is reporting KMIP errors since the restart:"
  printf '%s\n' "$e" | tail -5 | jq -r '"      \(.time) \(.message)"' 2>/dev/null || printf '%s\n' "$e" | tail -5
  log "KMIP errors after switch: $(printf '%s' "$e" | wc -l | tr -d ' ') lines"
  say "  Keys may not be retrievable from CipherTrust. Do not reboot or import pools in this state."
  if confirm "Roll back to the previous key manager configuration now (recommended)?"; then
    step_rollback; die "Switched back after KMIP errors. Investigate before retrying (see $KLOG)."
  fi
  die "Left on KMIP with errors at your request."
}

manual_export_info() { keyadm -j peer list 2>/dev/null | jq -r '.ExportInfo.KeyArchiveExport | "\(.PrevExportTime // "")\t\(.PrevExportUser // "")\t\(.PrevExportHost // "")"'; }

typed_confirm() { # typed_confirm WORD "what happened" — for builds without keyadm
  [ "${MANUAL_CONFIRM:-}" = "$1" ] && { log "env-confirmed: $2"; return 0; }
  [ -t 0 ] || die "Cannot confirm automatically on this build: $2. Run interactively."
  local a; read -r -p "  Type $1 once $2: " a; log "typed: $a"; [ "$a" = "$1" ] || die "Not confirmed."
}

wait_manual_export() { # waits until the key manager records a new manual export (internal exports do not count)
  say ""; say "  ${B}Action in Hub:${N} System > Encryption > Export Encryption Keys (set a password, save the file off the appliance)."
  if ! have_keyadm; then typed_confirm EXPORTED "the export has finished and the file is saved"; return; fi
  local before; before=$(manual_export_info | cut -f1)
  say "  Waiting for the export (previous manual export: ${before:-never}). Ctrl-C to stop; re-run 'switch' later."
  local i cur
  for i in $(seq 1 720); do
    cur=$(manual_export_info)
    if [ -n "$(printf '%s' "$cur" | cut -f1)" ] && [ "$(printf '%s' "$cur" | cut -f1)" != "$before" ]; then
      ok "Manual export recorded at $(printf '%s' "$cur" | cut -f1 | cut -c1-19)Z by $(printf '%s' "$cur" | cut -f2) from $(printf '%s' "$cur" | cut -f3)"
      return 0
    fi
    sleep 5
  done
  die "Timed out waiting for a manual key export."
}

wait_keys_present() { # waits until every key recorded before the switch is visible through the new key manager
  say ""; say "  ${B}Action in Hub:${N} System > Encryption > Import Encryption Keys (choose the archive you just exported, enter its password)."
  if ! have_keyadm || [ ! -s "$STATE_DIR/keys-before.json" ]; then typed_confirm IMPORTED "Hub reports the import finished without errors"; return; fi
  local total; total=$(jq length "$STATE_DIR/keys-before.json")
  say "  Waiting until all $total keys are on the key server. Ctrl-C to stop; run 'check' later."
  local i missing now
  for i in $(seq 1 720); do
    now=$(keys_json)
    if [ -n "$now" ]; then
      missing=$(jq -rn --slurpfile b "$STATE_DIR/keys-before.json" --argjson a "$now" \
        '($a|map("\(.IdType)/\(.Id)")) as $have | [$b[0][] | "\(.IdType)/\(.Id)" | select(. as $k | $have | index($k) | not)] | length')
      [ "$missing" = 0 ] && { ok "All $total keys are on the key server"; return 0; }
    fi
    sleep 5
  done
  die "Timed out: $missing of $total keys are still missing on the key server. Run 'check' for the list."
}

step_switch() {
  hdr "Switch the key manager to CipherTrust"
  need_root; load_settings
  [ -n "$KMIP_HOST" ] && [ -n "$ZONE" ] || die "Run the 'server' step first."
  step_verify
  local cur; cur=$(km_type)
  local cz; cz=$(conf_get KmipZone)
  [ "$cur" != Local ] && [ -n "$cz" ] && [ "$cz" != "$ZONE" ] && die "Existing KMIP zone is '$cz', not '$ZONE'. Changing it would hide existing keys."
  local nkeys=0
  if have_keyadm; then nkeys=$(keys_json | jq 'length' 2>/dev/null) || nkeys=unknown; [ -n "$nkeys" ] || nkeys=unknown
  else nkeys=unknown; fi
  snapshot_before before
  ok "Recorded keys, encrypted datasets and SED state before the switch ($STATE_DIR)"
  if [ "$cur" = Local ] && [ "$nkeys" != 0 ]; then
    say "  This appliance holds ${nkeys} keys in the Local key manager. They must be exported now and"
    say "  imported after the switch. Keep the archive and its password off the appliance."
    wait_manual_export
  elif [ "$cur" = Local ]; then ok "No keys in the Local key manager; no migration needed"
  else warn "Current type is $cur; the switch will only refresh the KMIP settings"; fi
  say ""; say "  The change applies to the whole appliance. Unlocked datasets and drives keep working."
  confirm "Switch the key manager to KMIP ($KMIP_HOST:$KMIP_PORT, zone $ZONE) now?" || die "Not switched."
  local bk; bk=$STATE_DIR/keymgrd.conf.$(date -u +%Y%m%dT%H%M%SZ); cp -p "$KCONF" "$bk"
  [ -f "$STATE_DIR/keymgrd.conf.orig" ] || cp -p "$KCONF" "$STATE_DIR/keymgrd.conf.orig"
  ok "Backed up $KCONF to $bk"
  local tmp; tmp=$(mktemp)
  sed -e "s|^Type = .*|Type = \"KMIP\"|" \
      -e "s|^KmipHost = .*|KmipHost = \"https://$KMIP_HOST:$KMIP_PORT\"|" \
      -e "s|^KmipCAFile = .*|KmipCAFile = \"$CERT_DIR/certauth.pem\"|" \
      -e "s|^KmipClientKeyFile = .*|KmipClientKeyFile = \"$CERT_DIR/clientkey.pem\"|" \
      -e "s|^KmipClientCertFile = .*|KmipClientCertFile = \"$CERT_DIR/clientcert.pem\"|" \
      -e "s|^KmipZone = .*|KmipZone = \"$ZONE\"|" \
      -e "s|^KmipInsecureSkipVerify = .*|KmipInsecureSkipVerify = false|" "$KCONF" > "$tmp"
  for k in Type KmipHost KmipCAFile KmipClientKeyFile KmipClientCertFile KmipZone; do grep -q "^$k = " "$tmp" || { rm -f "$tmp"; die "$KCONF has no '$k' line; not changed."; }; done
  cat "$tmp" > "$KCONF"; rm -f "$tmp"; KM_CHANGED=1
  ok "Updated $KCONF"
  restart_km KMIP
  echo "$(now_utc)" > "$STATE_DIR/switched-at"
  check_kmip_traffic
  if [ "$cur" = Local ] && [ "$nkeys" != 0 ]; then
    wait_keys_present
  fi
  step_check
}

step_check() {
  hdr "Check keys, datasets and drives"
  need_root; load_settings
  local fail=0
  [ "$(km_type)" = KMIP ] && ok "Key manager type is KMIP" || { bad "Key manager type is $(km_type)"; fail=1; }
  if have_keyadm; then
    local now; now=$(keys_json)
    if [ -z "$now" ]; then bad "keyadm did not answer (key manager not responding?)"; fail=1
    else
      local nn; nn=$(printf '%s' "$now" | jq 'length'); ok "Keys visible through CipherTrust: $nn"
      local errs; errs=$(printf '%s' "$now" | jq -r '.[] | select(.Error != "") | "\(.IdType)/\(.Id): \(.Error)"')
      [ -z "$errs" ] || { bad "Keys with errors:"; printf '%s\n' "$errs" | sed 's/^/      /'; fail=1; }
      if [ -s "$STATE_DIR/keys-before.json" ]; then
        local missing; missing=$(jq -rn --slurpfile b "$STATE_DIR/keys-before.json" --argjson a "$now" \
          '($a|map("\(.IdType)/\(.Id)")) as $have | $b[0][] | "\(.IdType)/\(.Id)" | select(. as $k | $have | index($k) | not)')
        if [ -z "$missing" ]; then ok "Every key present before the switch ($(jq length "$STATE_DIR/keys-before.json")) is on CipherTrust"
        else bad "Keys missing on CipherTrust:"; printf '%s\n' "$missing" | sed 's/^/      /'; fail=1; fi
      fi
    fi
  fi
  step_recover_keys quiet || fail=1
  local ids; ids=$(sed_enrolled_ids)
  if [ -n "$ids" ]; then
    local vout; vout=$(secadm verify keys $ids 2>&1); local rc=$?
    [ $rc = 0 ] && ok "SED key verification passed for $(printf '%s\n' "$ids" | grep -c .) enrolled drives" \
      || { bad "SED key verification reported problems:"; printf '%s\n' "$vout" | tail -10 | sed 's/^/      /'; fail=1; }
  else ok "No enrolled SED drives to verify"; fi
  if [ $fail = 0 ]; then
    say ""; ok "${B}All checks passed.${N} Export a fresh key archive in Hub (System > Encryption > Export Encryption Keys) and store it off the appliance."
  else
    say ""; warn "Some checks failed. Data that was already unlocked is still available. Re-run 'check' after fixing, or 'rollback' to return to the previous configuration."
    return 1
  fi
}

step_recover_keys() { # load and mount encrypted datasets that should be available but are not
  [ "$1" = quiet ] || { hdr "Load keys for locked datasets"; need_root; }
  local base=$STATE_DIR/datasets-before.tsv cur; cur=$(enc_snapshot)
  local todo
  if [ -s "$base" ]; then
    todo=$(awk -F'\t' 'NR==FNR{if($2=="available") want[$1]=1; next} want[$1] && $2!="available"{print $1}' "$base" <(printf '%s\n' "$cur"))
  else
    todo=$(printf '%s\n' "$cur" | awk -F'\t' '$2!="available" && $1 !~ /\/vault\//{print $1}')
    [ -n "$todo" ] && warn "No baseline recorded; trying every locked dataset except sealed vaults"
  fi
  if [ -z "$todo" ]; then ok "Every encrypted dataset that was unlocked before is unlocked now"; return 0; fi
  local d i failed=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    for i in 1 2 3 4 5; do
      bsrzfs load-key "$d" >/dev/null 2>&1
      [ "$(zfs get -H -o value keystatus "$d")" = available ] && break
      sleep $((i*3))
    done
    if [ "$(zfs get -H -o value keystatus "$d")" = available ]; then
      bsrzfs mount "$d" >/dev/null 2>&1
      ok "Loaded key and mounted: $d"
    else bad "Could not load key for: $d"; failed=1; fi
  done <<< "$todo"
  return $failed
}

step_rollback() {
  hdr "Roll back to the previous key manager configuration"
  need_root
  local orig=$STATE_DIR/keymgrd.conf.orig
  [ -s "$orig" ] || die "No saved original configuration in $STATE_DIR."
  local t; t=$(sed -n 's/^Type = "\(.*\)"/\1/p' "$orig")
  say "  This restores $KCONF from $orig (type $t) and restarts the key manager."
  if [ "$t" = Local ] && [ -f "$STATE_DIR/switched-at" ]; then
    warn "Keys created after the switch exist only on CipherTrust. Export keys in Hub first and import them after the rollback, or those datasets will stay locked."
  fi
  confirm "Roll back now?" || die "Not rolled back."
  cp -p "$KCONF" "$STATE_DIR/keymgrd.conf.before-rollback.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$orig" "$KCONF"
  restart_km "$t"
  rm -f "$STATE_DIR/switched-at"; KM_CHANGED=0
  ok "Rolled back to $t. Run 'check' or review Hub > System > Encryption."
}

step_bundle_export() {
  hdr "Export client identity for the HA peer node"
  need_root; load_settings
  for f in clientkey.pem clientcert.pem certauth.pem; do [ -s "$CERT_DIR/$f" ] || die "Missing $CERT_DIR/$f"; done
  local out=$STATE_DIR/ciphertrust-identity-$(hostname).tar
  ( cd "$CERT_DIR" && tar cf "$out" clientkey.pem clientcert.pem certauth.pem ) || die "tar failed"
  cp "$SETTINGS" "$STATE_DIR/peer-settings.env"; ( cd "$STATE_DIR" && tar rf "$out" peer-settings.env ); rm -f "$STATE_DIR/peer-settings.env"
  chmod 600 "$out"
  ok "Wrote $out (contains the private key: copy it directly to the peer node with scp, then delete it)"
  say "  On the peer node: $0 bundle-import $out"
}

step_bundle_import() {
  hdr "Import client identity from the HA peer node"
  need_root
  local in=$1; [ -s "$in" ] || die "Usage: $0 bundle-import <file.tar>"
  mkdir -p "$CERT_DIR" "$STATE_DIR"; chmod 700 "$CERT_DIR" "$STATE_DIR"
  [ -s "$CERT_DIR/clientkey.pem" ] && ! confirm "$CERT_DIR already has a client key. Replace it?" && die "Not replaced."
  ( cd "$CERT_DIR" && tar xf "$in" clientkey.pem clientcert.pem certauth.pem ) || die "tar extract failed"
  ( cd "$STATE_DIR" && tar xf "$in" peer-settings.env && mv peer-settings.env settings.env ) || true
  chmod 600 "$CERT_DIR"/*.pem
  ok "Installed client identity and settings. Next: '$0 server' (adds the hosts entry on this node), then 'verify' and 'switch'."
  warn "Delete $in now that it is installed."
}

step_status() {
  hdr "Status"
  load_settings
  ok "Key manager type: $(km_type) · service $(svc_state) · zone $(conf_get KmipZone)"
  [ -n "$(conf_get KmipHost)" ] && ok "Key server: $(conf_get KmipHost)"
  [ -s "$CERT_DIR/clientcert.pem" ] && ok "Client certificate: $(openssl x509 -in "$CERT_DIR/clientcert.pem" -noout -subject -enddate | tr '\n' ' ')"
  have_keyadm && ok "Keys: $(keys_json | jq 'length' 2>/dev/null || echo 'key manager not answering')"
  local enc; enc=$(enc_snapshot); ok "Encrypted datasets: $(printf '%s\n' "$enc" | grep -c .) (locked: $(printf '%s\n' "$enc" | awk -F'\t' '$2!="available"' | grep -c .))"
  local errs; errs=$(awk -F'"time":"' '/"level":"error"/ && !/invalid credentials/ {print substr($2,1,19)}' "$KLOG" 2>/dev/null | tail -1)
  [ -n "$errs" ] && warn "Last key manager error logged at $errs UTC (see $KLOG)"
}

usage() {
  cat <<EOF
brickstor-ciphertrust-setup.sh $VERSION — CipherTrust Manager KMIP setup for BrickStor SP

Usage: $0 <step> [options]

Steps (run in this order, or use 'run' for all of them):
  preflight       check the appliance, tools, current key manager, keys, datasets, SEDs
  server          set the KMIP address, check its certificate name, add a hosts entry
  prepare         create the client key (stays on the appliance) and certificate request
  register        register with CipherTrust: automatic through its API, or console steps
  verify          check certificates and mutual TLS to the key server
  switch          export keys (Hub), switch to KMIP, import keys (Hub), then 'check'
  check           confirm every key, dataset and enrolled SED works through CipherTrust
  recover-keys    load keys for datasets that should be unlocked but are not (for example after a reboot)
  status          one-screen summary
  rollback        restore the configuration saved before the switch
  bundle-export   (HA) package the client identity for the peer node
  bundle-import F (HA) install that package on the peer node
  run             guided: preflight, server, prepare, register, verify, switch

Options (environment): YES=1 accept defaults and confirmations; STATE_DIR (default /var/racktop/ciphertrust-setup);
  CERT_DIR (default /etc/racktop/keymgrd/ciphertrust); any setting below can be preset, for example
  KMIP_ADDR, KMIP_HOST, KMIP_PORT, ZONE, CN, CM_ADDR, CM_USER; CM_PASSWORD_FILE (root-only file, for automation).
Settings are kept in $SETTINGS; a transcript is written to $TRANSCRIPT. No passwords are stored.
EOF
}

main() {
  local cmd=${1:-help}; shift || true
  mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null
  load_settings
  log "---- $0 $VERSION: $cmd $*"
  case $cmd in
    preflight) step_preflight;; server) step_server;; prepare) step_prepare;; register) step_register;;
    verify) step_verify;; switch) step_switch;; check) step_check;; recover-keys) step_recover_keys;;
    status) step_status;; rollback) step_rollback;; bundle-export) step_bundle_export;; bundle-import) step_bundle_import "$@";;
    run) step_preflight; step_server; step_prepare; step_register; step_verify; step_switch;;
    help|-h|--help) usage;;
    *) usage; exit 2;;
  esac
}
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
