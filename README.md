# RackTop Systems support tools

Scripts and guides that RackTop Support shares with customers of BrickStor SP.
Everything here is public. Each tool lives in its own directory with a README
that says what it does, which BrickStorOS versions it supports, and how to undo
it.

## Tools

| Directory | What it does | Status |
| --- | --- | --- |
| [ciphertrust-kmip-setup](ciphertrust-kmip-setup/) | Connects BrickStor SP to Thales CipherTrust Manager as its KMIP key manager, with a matching Hub and CLI setup guide. | Preview |

## Getting a tool

Download on your workstation, check the checksum, then copy it to the appliance:

```sh
curl -fsSLO https://raw.githubusercontent.com/racktopsystems/support/main/ciphertrust-kmip-setup/brickstor-ciphertrust-setup.sh
curl -fsSLO https://raw.githubusercontent.com/racktopsystems/support/main/ciphertrust-kmip-setup/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Read a script before you run it. Each one explains, in its README, what it
changes and how to roll back.

## Support

These tools are provided by RackTop Support. If something does not behave as
described in a tool's README, contact RackTop Support and include the transcript
or log file that README names.

## Contributing (RackTop engineers)

Read [AGENTS.md](AGENTS.md) before adding or changing anything. This repository
is public: the rules there on secrets and internal details are mandatory.
