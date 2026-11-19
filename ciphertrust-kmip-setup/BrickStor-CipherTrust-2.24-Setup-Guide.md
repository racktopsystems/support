# Configure BrickStor SP with CipherTrust Manager 2.24 (Hub and CLI)

Configure CipherTrust Manager as the external KMIP key manager for BrickStor SP. BrickStor uses the same KMIP connection for self-encrypting drive (SED) unlock keys and ZFS dataset encryption keys. Choose the storage procedures that apply to your deployment.

This guide gives each task two ways: **Hub** (the BrickStor web interface) and **CLI** (the BrickStor administrative shell). Use Hub wherever it is offered. Some steps have no Hub screen on current builds and are marked **CLI only**.

Use this procedure on BrickStorOS builds that support the generic `KMIP` key manager. For an HA deployment, confirm the configuration and key access plan for each node with RackTop Support before changing the active key manager.

## What Hub covers

| Step | Task | Hub | CLI |
| --- | --- | --- | --- |
| 2 | Export existing keys | Yes | Not needed |
| 3 | Prepare CipherTrust Manager | CipherTrust console | CipherTrust API |
| 4 | Create client key and CSR | **No** | Yes (CLI only) |
| 4 | Register client, install certificates | CipherTrust console, then file transfer | CipherTrust API |
| 5 | Add a hosts entry for the KMIP server name | **No** (Hub manages DNS servers only) | Yes (CLI only) |
| 5 | Set the KMIP endpoint | **No** | Yes (CLI only) |
| 5 | Confirm Key Manager is KMIP and Online | Yes | Yes |
| 6 | Import existing keys | Yes | Not needed |
| 6, 7 | Verify and enroll SEDs | Yes (see note in step 7) | Yes |
| 7 | Create an encrypted dataset | Yes | Yes |
| 8 | Back up keys after changes | Yes | Not needed |

On current builds, Hub's Encryption page shows the key manager **Type** and **Status** but has no fields to change them. Configure the KMIP endpoint from the shell, then use Hub to confirm and to move keys.

## 1. Prepare the appliances

- Confirm you have BrickStor appliance administration access (including shell access with administrator privileges) and a CipherTrust administrator who can manage the KMIP interface and register clients.
- In CipherTrust Manager, confirm **KMIP** is active under **Licensing → Features**. If needed, install your KMIP license before proceeding.
- Confirm BrickStor can resolve the CipherTrust KMIP hostname and reach it on TCP port **5696**. The hostname must be one listed in the KMIP server certificate's subject alternative name (SAN). Connecting by IP address fails verification unless the certificate lists that IP. Synchronize the clocks on both appliances.
- For SED protection, confirm the BrickStor TCG license is active and the target drives support SED management. Record the pool GUID and drive IDs. Keep the inventory outside the pool.
  - **CLI:** `secadm list all`
  - **Hub:** Rack View, select the drive or pool.
- In Hub, accept the end-user license agreement if prompted. Until it is accepted, Hub redirects the Encryption page to **System → Licenses** (**Accept EULA required**). Confirm the **TCG_Encryption** feature is listed there if you plan to use SEDs.
- Confirm a data pool exists. A new appliance has only the system pool, which cannot hold an encrypted test dataset. In Hub, open **Pools → Overview → Create Pool**, enter a name, choose the available drives and select **Create Pool**.
- If BrickStor already manages encryption keys, schedule a maintenance window. The key manager setting applies to the entire appliance, including encrypted datasets and drives outside the target pool.

Examples below use `ciphertrust.example.com` for the server, `brickstor01-kmip` for the dedicated CipherTrust user and certificate common name, and `brickstor01` for the client name and BrickStor KMIP zone. Substitute your own values.

## 2. Export existing BrickStor keys

Complete this section before switching the key manager if the appliance already holds keys.

**Hub**

1. Open **System → Encryption** and select **Export Encryption Keys**.
2. Enter a password and re-type it. If you leave the password empty, Hub generates a 256-bit random password for the archive; record it when the export completes.
3. (Optional) Change the file name. Hub adds the `.enc` extension.
4. Select **Export**. Your browser saves the encrypted archive.

**CLI:** No shell command is required. Use Hub for the full export.

Save the encrypted archive and its key report outside BrickStor, and keep the password separately in your password manager. Keep the original key manager and its store available until recovery from the new store is confirmed.

Use the full encryption key export for the migration. A drive-only SED key export covers drive keys only. If you cannot obtain a complete export, resolve that before switching providers. [RackTop BrickStor user guides and support](https://www.racktopsystems.com/support)

## 3. Prepare CipherTrust Manager

**CipherTrust console**

1. In **Admin Settings → Interfaces**, open the KMIP interface. Confirm the service is enabled on port **5696** and the mode is **TLS, verify client cert, user name taken from client cert, auth request is optional** (`tls-cert-pw-opt`).
2. Use **CN** for certificate username mapping. The registered client uses the mapping from its client profile. Ensure the KMIP interface trusts the CA issuing the client certificate. Coordinate any changes to an interface shared with other clients.
3. In **Admin Settings → Users**, create the dedicated local user `brickstor01-kmip`. Add it to **Key Users**. Use an administrator account with KMIP client registration permissions to create the profile and register the client.

**CLI (CipherTrust API):** See [Certificate registration with the CipherTrust API](#certificate-registration-with-the-ciphertrust-api). User creation uses `POST /api/v1/usermgmt/users/` and group membership uses `POST /api/v1/usermgmt/groups/Key%20Users/users/{user_id}`.

[CipherTrust Manager 2.24 KMIP reference](https://docs-cybersec.thalesgroup.com/bundle/latest-cdsp-cm/page/reference/kmip-ref/index.html)

## 4. Register BrickStor and install its certificates

**CLI only: create the client key and CSR.** Hub's certificate screens apply to the Hub web server, not the key manager. On the BrickStor administrative shell, with administrator (root) privileges, create the client private key and certificate signing request (CSR). Choose a new certificate directory if the example directory already contains a private key.

```sh
umask 077
certdir=/etc/racktop/keymgrd/ciphertrust
mkdir -p "$certdir"
openssl req -new -newkey rsa:3072 -nodes \
  -keyout "$certdir/clientkey.pem" \
  -out "$certdir/client.csr" \
  -subj /CN=brickstor01-kmip
```

Keep `clientkey.pem` on BrickStor with owner-only permissions. The key manager loads the PEM file directly, so it must be readable without a passphrase.

Register the client in CipherTrust (console steps below; the equivalent API calls are in the appendix):

1. Open **KMIP → Client Profile** and add a profile. Choose **Bring your own key**, supply the PEM CSR from BrickStor, and set **Username Location in Certificate** to **CN**. Preserve the subject DN and select a certificate lifetime that meets your policy. The CSR common name must match the dedicated CipherTrust username.
2. Open **KMIP → Registration Token** and create a token for that profile. Select the issuing local CA and set the client capacity to one. Set a lifetime that allows time to finish registration.
3. Open **KMIP → Registered Clients** and add the BrickStor client using the token. Save the signed certificate returned by CipherTrust as `clientcert.pem`.
4. Obtain the CA certificate or chain that validates the certificate presented by the **KMIP server**. Save it as `certauth.pem`. If the server and client certificates were issued by different CAs, use the server's CA chain in this file and configure the client's issuing CA in CipherTrust.
5. Transfer both certificate files to `/etc/racktop/keymgrd/ciphertrust/` using your approved file transfer method. Set permissions on the appliance.

```sh
chmod 700 /etc/racktop/keymgrd/ciphertrust
chmod 600 /etc/racktop/keymgrd/ciphertrust/clientkey.pem \
  /etc/racktop/keymgrd/ciphertrust/clientcert.pem \
  /etc/racktop/keymgrd/ciphertrust/certauth.pem
```

Before changing the key manager, confirm the files match and that mutual TLS works from BrickStor:

```sh
cd /etc/racktop/keymgrd/ciphertrust
openssl verify -CAfile certauth.pem clientcert.pem
openssl x509 -noout -modulus -in clientcert.pem | openssl md5
openssl rsa  -noout -modulus -in clientkey.pem  | openssl md5      # must print the same hash
echo | openssl s_client -connect ciphertrust.example.com:5696 \
  -CAfile certauth.pem -cert clientcert.pem -key clientkey.pem \
  -verify_hostname ciphertrust.example.com | grep -E 'Verify return|Verification'
```

If you use the CipherTrust API for registration, see [Certificate registration with the CipherTrust API](#certificate-registration-with-the-ciphertrust-api).

## 5. Set the BrickStor KMIP endpoint

Work in the BrickStor administrative shell. Hub does not offer these settings on current builds.

**CLI only: name resolution.** If the KMIP server name is not in DNS, add it with the BrickStor utility. Do not edit `/etc/hosts` by hand: the file is machine-generated and manual changes are lost.

```sh
export PATH=/usr/racktop/sbin:$PATH
bsradm hosts add --comment "CipherTrust KMIP server" 192.0.2.10 ciphertrust.example.com
bsradm hosts show
```

**CLI only: set the endpoint.** Back up the current key manager configuration in a protected location before editing it. Keep the original key store as part of your recovery plan.

```sh
mkdir -p /var/racktop/ciphertrust-recovery   # /root does not survive a reboot on BrickStor
cp -p /etc/racktop/keymgrd/keymgrd.conf /var/racktop/ciphertrust-recovery/keymgrd.conf.orig
```

In `/etc/racktop/keymgrd/keymgrd.conf`, update the following fields. Keep the remaining settings from your current file and use the certificate paths from step 4.

```toml
Type = "KMIP"
KmipHost = "https://ciphertrust.example.com:5696"
KmipCAFile = "/etc/racktop/keymgrd/ciphertrust/certauth.pem"
KmipClientKeyFile = "/etc/racktop/keymgrd/ciphertrust/clientkey.pem"
KmipClientCertFile = "/etc/racktop/keymgrd/ciphertrust/clientcert.pem"
KmipZone = "brickstor01"
KmipInsecureSkipVerify = false
```

Choose a nonempty `KmipZone` for the BrickStor key namespace. Keep it stable once keys exist. BrickStor uses this value to find its keys on CipherTrust.

Restart the key manager using the BrickStor administration utility.

```sh
export PATH=/usr/racktop/sbin:$PATH
bsradm smf restart svc:/racktop/keymgrd:default
```

**Confirm the key manager (Hub or CLI)**

- **Hub:** Open **System → Encryption**. In the **Key Manager** card, confirm **Type** is **KMIP** and **Status** is **Online**. Resolve any reported problem before continuing.
- **CLI:** Check the service and its log.

```sh
svcs svc:/racktop/keymgrd:default
tail /var/log/keymgrd/keymgrd.log
```

The log line `Set up key manager` with `"Type":"KMIP"` confirms the new type was loaded. The status can read Online while key operations are still untested, so continue to step 6 and confirm real key traffic.

## 6. Import existing keys and confirm access

If you exported existing keys in step 2, complete the migration before allowing operations that depend on those keys.

**Hub**

1. Open **System → Encryption** and select **Import Encryption Keys**.
2. Choose the `.enc` archive from step 2 (**Choose File**) and enter its password.
3. Select **Import**. Hub lists the imported keys with a count and reports **Operation Successful** when the import completes.
4. Compare the count and identifiers with the original export. Investigate any missing identifier or key before returning affected storage to service.
5. In CipherTrust Manager, open **Keys** and confirm the new objects appear. Each imported key is a separate AES-256 object, so the count of new CipherTrust keys should equal the count Hub reports.

**CLI:** No shell command is required for key import. Use Hub.

Then verify SED keys and dataset access:

1. **Verify enrolled SED keys for each affected pool.**
   - **Hub:** In the hardware view, select the intended pool and choose **SED Verify Key**.
   - **CLI:** `secadm verify keys DRIVE_ID_1 DRIVE_ID_2` with the recorded drive IDs.
2. **Confirm you can access the affected encrypted datasets.** If your maintenance plan includes recovery testing, confirm key retrieval on storage taken offline for that purpose. Access to a dataset that already has its key loaded can succeed before migration is complete.
   - **Hub:** The **Dataset Encryption** card on the Encryption page shows the number of encrypted datasets.
   - **CLI:** `zfs get keystatus,mounted DATASET`

Existing drive enrollment can be retained when the matching keys are available in the new store. If migration fails, preserve both key stores and follow your recovery plan before enabling any further encryption operations. Before switching back to the original configuration, ensure the original store has any keys created or changed since the migration.

## 7. Enable protection for new storage

### Enroll self-encrypting drives

**Hub:** In the hardware view, select the intended pool or eligible unassigned drives and choose **SED Enroll** (the dialog is titled **Enable SED Protection**). Confirm the displayed scope. Selecting a pool member enrolls every drive in that pool.

**CLI:** For pool enrollment, substitute your pool GUID and actual drive IDs below.

```sh
secadm list all
secadm enroll --pool POOL_GUID
secadm list all
secadm verify keys DRIVE_ID_1 DRIVE_ID_2
```

Review enrollment and verification results for each intended drive. BrickStor obtains the drive unlock keys from CipherTrust once the external key manager is active.

### Create an encrypted ZFS dataset

**Hub**

1. Open **Datasets**. On an appliance with existing datasets, select **Create**. On a new pool with no datasets, open the pool's row action menu and select **Add Child** instead: **Create** can show **parent required** with no parent to choose.
2. Under **New Path**, check the pool or parent dataset and enter the dataset name. Ensure the parent is mounted.
3. Choose a **Storage Profile**.
4. Under **Options**, select **Dataset Encryption**. Select any sharing options the workload needs. Leave SMB, NFS, S3 and Web Drive cleared for a private test dataset.
5. Select **Next** to configure the remaining pages (Permissions, Storage Settings, Active Defense, Data Protection, Replication), or **Skip to confirmation**.
6. On **Confirmation**, check that the summary lists **AES-256 encrypted**, then select **Create Dataset**.
7. In CipherTrust Manager, confirm a new AES-256 key appears under **Keys**.

**CLI**

```sh
bsrzfs create --encrypt --algorithm aes-256-gcm \
  --opt sharenfs=off --opt sharesmb=off tank/secure-data
```

Confirm the result (Hub or CLI):

```sh
zfs get encryption,keystatus,mounted,racktop:keyid tank/secure-data
```

Expect `aes-256-gcm`, `available` and `yes`. The `racktop:keyid` value is the identifier of the dataset's key on CipherTrust.

Enable dataset encryption when you create the dataset. To encrypt data in an existing unencrypted dataset, create an encrypted destination and move the data under your normal migration procedure. Hub creates datasets under the pool's `global` parent, so the full path can include `global` (for example `tank/global/secure-data`).

### Confirm key retrieval from CipherTrust

To prove BrickStor can fetch a dataset key from CipherTrust, unload the key, restart the key manager, then load the key and compare a checksum.

```sh
export PATH=/usr/racktop/sbin:$PATH
ds=tank/global/secure-data
sha256_before=$(digest -a sha256 /storage/$ds/payload.bin)
zfs unmount $ds
zfs unload-key $ds
bsradm smf restart svc:/racktop/keymgrd:default
bsrzfs load-key $ds
bsrzfs mount $ds
test "$sha256_before" = "$(digest -a sha256 /storage/$ds/payload.bin)" && echo MATCH
```

## 8. Back up the new configuration and keys

After key migration or provisioning, save a fresh BrickStor archive.

**Hub:** Open **System → Encryption** and select **Export Encryption Keys**. Hub reports **Manual backup required** whenever new keys have been added since the last export.

Keep the archive password separate. Include CipherTrust and the BrickStor client certificate configuration in your recovery procedure, and plan certificate renewal before expiry. Keep `/var/racktop/ciphertrust-recovery/keymgrd.conf.orig` with the archives.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Key Manager fails to come online | Confirm DNS and TCP 5696 reachability. Check the server hostname against its certificate SAN, the trust chain, and the client certificate's renewal date and matching private key. Use `bsradm smf daemonlog svc:/racktop/keymgrd:default` to locate the service log (`/var/log/keymgrd/keymgrd.log`). |
| TLS connects but key operations fail | Check KMIP licensing, client registration, the certificate CN mapping, and the user's **Key Users** membership. Review the CipherTrust audit or configured log destination for the client. |
| Key Manager shows Online but the log has `Failed to connect to KMIP server ... message cannot be parsed 42005c not supported` | This message can appear at service start without affecting key operations. Treat key import, dataset creation and key retrieval as the real test. If key operations fail too, check the items in the two rows above. |
| Hub opens **System → Licenses** instead of **Encryption** | The EULA has not been accepted. Accept it under **System → Licenses**, then reopen the Encryption page. |
| Hub shows **RPC request timed out (keymgrd.GetInfo)** on **System → Overview** or **Encryption**, or `bsrzfs load-key` reports **RPC service unavailable (keymgrd...)** | The key manager process is not answering, even though CipherTrust may be healthy. Check `svcs -xv svc:/racktop/keymgrd:default` and `/var/log/keymgrd/keymgrd.log`. Save the log first, then restart with `bsradm smf restart svc:/racktop/keymgrd:default`. If the restart leaves the service in **maintenance** (it did not stop within the SMF timeout), run `svcadm clear svc:/racktop/keymgrd:default`, then confirm **Type KMIP / Status Online** in Hub and retrieve a dataset key with `bsrzfs load-key`. Datasets whose keys are already loaded stay mounted while the service is down, but unloading a key or rebooting needs the key manager to be running. Report the occurrence with the log to RackTop Support. |
| Hostname does not resolve | Add the entry with `bsradm hosts add`. Do not edit `/etc/hosts` directly; it is regenerated. |
| Previously accessible keys are missing | Check the archive import results, the CipherTrust domain and client identity, and the original `KmipZone`. Keep the original store available until key access is restored. |
| Dataset creation reports an unmounted parent | Mount the intended parent using `bsrzfs mount tank/parent`, then retry creation. For an existing encrypted dataset with an unloaded key, use `bsrzfs load-key tank/secure-data` and mount it with `bsrzfs mount`. |
| BrickStor cannot find a pool whose SEDs are locked | Unlock using the recorded drive IDs with `secadm unlock --drive DRIVE_ID_1 --drive DRIVE_ID_2`. When all member drives are locked their pool labels may be inaccessible. |
| Hub reports key peers offline or out of sync | This concerns key replication between appliance peers, which is separate from the KMIP connection. Fix peer credentials or remove the peer under **System → System Peers**. |

### Certificate registration with the CipherTrust API

In the authenticated CipherTrust API playground, use the KMIP profile, token, and registration operations below. Replace the example values. Provide the CSR as PEM text in the JSON string. Use the token immediately to register the client and save the returned certificate PEM.

| Operation | Method and path |
| --- | --- |
| Create client profile | `POST /api/v1/kmip/kmip-profiles` |
| Create registration token | `POST /api/v1/kmip/regtokens/` |
| Register client | `POST /api/v1/kmip/kmip-clients` |

Client profile payload

```json
{
  "name": "BrickStor-KMIP",
  "do_not_modify_subject_dn": true,
  "cert_duration": 365,
  "properties": {
    "cert_user_field": "CN",
    "csr": "<PEM CSR from BrickStor>"
  }
}
```

Registration token payload

```json
{
  "ca_id": "<issuing local CA ID>",
  "lifetime": "1h",
  "max_clients": 1,
  "profile_name": "BrickStor-KMIP",
  "name_prefix": "brickstor01"
}
```

Client registration payload

```json
{
  "name": "brickstor01",
  "reg_token": "<token returned by CipherTrust>"
}
```

[CipherTrust Manager 2.24 KMIP reference](https://docs-cybersec.thalesgroup.com/bundle/latest-cdsp-cm/page/reference/kmip-ref/index.html)

