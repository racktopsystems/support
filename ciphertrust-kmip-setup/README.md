# BrickStor SP + Thales CipherTrust Manager: guided KMIP setup

**Status: preview.** See [Supported versions](#supported-versions).

`brickstor-ciphertrust-setup.sh` connects a BrickStor SP appliance to Thales
CipherTrust Manager as its KMIP key manager. It replaces the hand-run OpenSSL,
file-editing and service-restart steps of the setup guide with checked,
repeatable steps, and stops before anything risky until you confirm.

It runs on the BrickStor appliance. Two steps stay in Hub on purpose: exporting
and importing the key archive. The script tells you when to do them, waits, and
checks the result.

## What it does for you

| Step | Done by the script |
| --- | --- |
| `preflight` | Checks tools, key manager service, current key manager type, number of keys, encrypted datasets, enrolled SEDs, HA membership, clock. |
| `server` | Connects to the KMIP port, reads the server certificate, makes sure the hostname you use is in the certificate, and adds a persistent hosts entry if it does not resolve. |
| `prepare` | Creates the client private key on the appliance (it never leaves) and the certificate request. |
| `register` | **Automatic:** logs in to the CipherTrust API (password prompted, never stored), checks the KMIP interface and licence, creates the KMIP user in Key Users, the client profile, a one-time registration token and the client, then installs the signed certificate and the server CA. **Manual:** prints the CSR and the console steps and installs the files you give it. |
| `verify` | Key and certificate match, expiry, CN, and a mutual-TLS connection with server name verification. |
| `switch` | Records every key, encrypted dataset and SED before the change; waits for your Hub export; backs up and edits `keymgrd.conf`; restarts the key manager (and clears SMF maintenance if the restart hangs); waits until every key is on CipherTrust after your Hub import; runs `check`. |
| `check` | Confirms every key from before the switch is on CipherTrust, every dataset that was unlocked is unlocked, and enrolled SEDs pass `secadm verify keys`. |
| `recover-keys` | Loads keys for datasets that should be unlocked but are locked. |
| `rollback` | Restores the configuration saved before the switch. |
| `bundle-export` / `bundle-import` | HA: copies the client identity to the second node. |
| `status` | One-screen summary. |

`run` does `preflight`, `server`, `prepare`, `register`, `verify` and `switch`
in order. Every step can be re-run; finished work is kept.

## Before you start

- A maintenance window. Switching the key manager is appliance-wide. Datasets
  and drives that are already unlocked keep working during the switch.
- Hub access to the appliance as an administrator, and root (or sudo) on the
  appliance shell.
- A CipherTrust administrator account (for automatic registration), the KMIP
  licence active, and the KMIP interface enabled (RackTop tested mode
  `tls-cert-pw-opt` on port 5696).
- Network: appliance to CipherTrust on TCP 5696 (KMIP) and 443 (API, automatic
  registration only).
- Clocks in sync (NTP) on both sides.

## Quick start

```sh
scp brickstor-ciphertrust-setup.sh admin@appliance:/var/tmp/
ssh admin@appliance
sudo bash /var/tmp/brickstor-ciphertrust-setup.sh run
```

Answer the prompts. When the script says **Action in Hub**, open Hub, go to
System → Encryption, do the export or import it names, and leave the script
running; it continues by itself once the action is detected.

After `All checks passed`, export a fresh key archive in Hub and store it, with
its password, off the appliance.

## HA clusters

Both nodes must use the same client identity and the same settings.

1. On node A: `preflight`, `server`, `prepare`, `register`, `verify`.
2. On node A: `bundle-export`. Copy the file it names to node B with `scp`, then
   delete it from both places once installed (it contains the private key).
3. On node B: `bundle-import <file>`, then `server` (adds the hosts entry on that
   node) and `verify`.
4. In one maintenance window: `switch` on the node that owns the pools, then
   `switch` on the other node, then `check` on both.

HA has not been validated with this script yet. Contact RackTop Support for a
supervised deployment.

## After a reboot

On current builds a key fetch can fail during boot and is not retried.
If a dataset that should be unlocked is locked after a reboot:

```sh
sudo bash /var/tmp/brickstor-ciphertrust-setup.sh recover-keys
```

It retries each affected dataset and mounts it. Sealed ImmutaVault datasets
are left alone.

## Undo

`rollback` restores the `keymgrd.conf` saved before the first switch and
restarts the key manager. Keys created after the switch exist only on
CipherTrust: export them in Hub before rolling back and import them after.

## Files

| Path | Contents |
| --- | --- |
| `/etc/racktop/keymgrd/ciphertrust/` | client key, client certificate, server CA (root only, mode 600) |
| `/var/racktop/ciphertrust-setup/settings.env` | answers you gave (no secrets) |
| `/var/racktop/ciphertrust-setup/transcript.log` | everything the script did (no secrets) |
| `/var/racktop/ciphertrust-setup/keymgrd.conf.*` | backups of the key manager configuration |
| `/var/racktop/ciphertrust-setup/keys-before.json`, `datasets-before.tsv`, `sed-before.json` | state recorded before the switch, used by `check` |

## Automation options

All prompts can be preset through the environment for unattended use:
`YES=1` accepts defaults and confirmations; `KMIP_ADDR`, `KMIP_HOST`,
`KMIP_PORT`, `ZONE`, `CN`, `CM_ADDR`, `CM_USER`, `CM_CA_SRC` preset answers;
`CM_PASSWORD_FILE` points at a root-only file holding the CipherTrust password
(delete it afterwards). `STATE_DIR` and `CERT_DIR` move the working and
certificate directories.

## Security notes

- The client private key is created on the appliance and is not copied
  anywhere except by `bundle-export`, which you run deliberately for HA.
- TLS verification is always on, both to the KMIP port and to the CipherTrust
  API. For the API the script shows the CA fingerprint and asks you to compare
  it with the CipherTrust console before trusting it.
- The CipherTrust user the script creates has console login disabled and is
  authenticated by its certificate.
- Passwords are prompted for and never written to disk or to the transcript.

## Supported versions

| Build | Status |
| --- | --- |
| BrickStorOS 23.9 and 23.10 with CipherTrust Manager 2.24 | Supported (preview). Local to KMIP migration, `rollback`, and key retrieval after a key manager restart and after a reboot. |
| BrickStorOS 23.8 | KMIP with CipherTrust 2.24 is not yet supported on this release. Contact RackTop Support before changing the key manager. |
| BrickStorOS 23.7, HA clusters, self-encrypting drives | Not yet validated with this script. Contact RackTop Support for a supervised deployment. On 23.7 and 23.8 (no `keyadm`) the export and import steps ask you to type a confirmation instead of detecting them. |

If setup stops with "A KMIP client named ... already exists", an earlier setup left a client with that certificate name on CipherTrust (it allows one client per name). Delete the old client in the console, or run `CN=<new-name> ./brickstor-ciphertrust-setup.sh prepare` and then `register`.

## Related files

| File | Purpose |
| --- | --- |
| [BrickStor-CipherTrust-2.24-Setup-Guide.md](BrickStor-CipherTrust-2.24-Setup-Guide.md) | The same setup done by hand, with Hub and CLI steps side by side. |
| `kmip-dataset-baseline.sh` | Optional, read-only. `record` before the switch and `compare` after it to confirm every encrypted dataset has the same key status, mount state and data checksum. |
| `SHA256SUMS` | Checksums for the files in this directory. |

## Getting help

Contact RackTop Support and attach `/var/racktop/ciphertrust-setup/transcript.log`. It contains no secrets.
