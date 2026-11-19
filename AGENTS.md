# Working in this repository (engineers and AI agents)

This repository is **public**. Anyone on the internet can read every file and
every commit, forever. It exists so customers can download support scripts and
guides. Write everything here for a customer reading it with no inside knowledge.

Read this file completely before you add or change anything.

## 1. What must never be committed

Stop and ask a RackTop security contact if you are unsure.

| Never commit | Examples |
| --- | --- |
| Credentials and key material | passwords, API tokens, `.env` files, private keys, certificates issued to a real system, key archives, license keys, session cookies |
| Customer data | customer or site names, hostnames, addresses, serial numbers, support bundle contents, pasted ticket text, log excerpts from a customer system |
| Internal addresses and names | lab or corporate IP addresses and hostnames, internal domains, VPN or jump hosts, user names and email addresses of staff |
| Internal systems | links to or keys from Jira, Confluence, Zendesk, Bitbucket, onRAMP, or any internal tool; ticket numbers such as `QA-123` or `BSR-123` |
| Internal test evidence | QA reports, lab appliance names and builds, timelines of what failed in testing, unreleased results |
| Implementation details | source code, function or module names, internal protocol behavior, root causes of defects, architecture. Describe what the product does, not how it is built |
| Unreleased plans | roadmap, unreleased versions or features, commitments to dates |

If something sensitive is committed, **do not just delete it in a later commit.**
The history keeps it. Tell your security contact immediately, rotate the secret,
and let them decide how to purge history.

Use these placeholders in examples:

- Addresses: `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` (reserved for documentation)
- Names: `example.com`, `ciphertrust.example.com`, `brickstor01`, `tank/secure-data`
- Secrets: `<password>`, `<token returned by the server>`. Never a realistic value.

## 2. Describe behavior, not internals

A customer needs to know what a step does, what it changes, and how to undo it.
Reference only commands, paths and settings that RackTop's customer
documentation already describes (for example `bsradm`, `bsrzfs`, the Hub
screens, `/var/racktop`). Do not explain how the product works inside.

Known issues that affect customers go in the README as plain operational
guidance: the symptom, the supported workaround, and "contact RackTop Support".
Leave out ticket numbers, causes, and blame.

## 3. Layout

```
README.md                  what is here, how to download and verify
AGENTS.md                  this file
scripts/                   repository tooling (check-publish.sh, update-checksums.sh)
templates/                 CUSTOMER-README.md
<tool-name>/               one directory per tool, kebab-case
    README.md              required, follows templates/CUSTOMER-README.md
    <script>.sh            the tool
    <guide>.md             optional long-form procedure
    SHA256SUMS             required, from scripts/update-checksums.sh
```

Add the tool to the table in the top-level `README.md`. Do not store test
reports, logs, captures, or drafts here. Those belong in internal systems.

## 4. How a customer README is structured

Copy `templates/CUSTOMER-README.md`. In short:

1. **Title and one-sentence purpose.** What the customer gets, not how it is built.
2. **Status and supported versions.** A table of BrickStorOS and third-party versions: supported, not yet supported, not yet validated. State plainly what is not covered. Do not describe lab testing; say "Supported" or "Not yet validated".
3. **What it does.** A table of steps or commands, and what each one changes.
4. **Before you start.** Access, permissions, maintenance window, network ports, time sync.
5. **Quick start.** The shortest correct path, in copy-paste commands.
6. **Detailed steps or usage**, including HA and other variants.
7. **Undo.** How to roll back, and what cannot be rolled back.
8. **Files.** What is created, where, and whether it holds secrets.
9. **Security notes.** Where secrets live, that TLS verification stays on, what is prompted for and never stored.
10. **Troubleshooting.** Symptom and action table.
11. **Getting help.** "Contact RackTop Support" and which file to attach.

Style: second person, present tense, imperative steps ("Run ...", "Open Hub ..."),
one H1, tables for matrices and short lists for steps, command blocks that can be
pasted, no marketing language, no internal jargon or abbreviations that are not
defined, no emoji. Say "Hub" and "CLI" consistently. Put anything risky or
irreversible before the step that does it. Do not promise what is not supported.

## 5. Script standards

- `#!/usr/bin/bash`, a header comment (purpose, usage, copyright), and a `VERSION` variable.
- Run `bash -n` and `shellcheck` before committing.
- Safe to re-run. Back up anything it changes, and provide an undo.
- Ask for confirmation before any change to production state or anything that can interrupt service. Support an unattended mode (for example `YES=1`) only through an explicit variable.
- Prompt for secrets and never write them to disk, to logs or transcripts, or onto a command line (visible in `ps`). Create files that hold secrets with mode 600.
- Keep TLS verification on. Never use `curl -k`, `--insecure`, or disable certificate checks. Show a fingerprint and ask the user to trust it if a CA is not yet known.
- No hard-coded addresses, hostnames, users, or paths specific to a site. Take them as prompts or environment variables.
- Persistent state goes where the target system keeps it across reboots, and the README lists it.
- Behavior that depends on the version must detect the version and say clearly when it is unsupported, instead of continuing.

## 6. Before every commit and pull request

1. Run `scripts/check-publish.sh`. It must pass. It catches private addresses, ticket keys, internal URLs, secret patterns, serial numbers and stray key or log files, and checks the checksums. It does not replace reading your diff.
2. Read the whole diff as a customer and as an attacker. Ask what it reveals about our network, our product internals, or other customers.
3. Run `scripts/update-checksums.sh <tool-directory>` after any change to a script or guide.
4. Open a pull request into `main` using the template. A second RackTop engineer reviews it before merge. Do not push directly to `main` and do not force-push; history is public.
5. Do not add AI-tool attribution to commits or pull requests: no `Co-Authored-By` trailer naming a tool, and no "Generated with ..." line. The engineer who commits is the author and answers for the change. See section 7.
6. Mark a tool **Preview** in the README until it is validated on every version listed as supported.

## 7. Notes for AI agents

- These rules apply to everything you write, including examples, comments, commit messages and pull request text.
- **No attribution lines.** Do not add `Co-Authored-By` trailers, "Generated with ..." footers, or any other mention of the tool you run on in commit messages, pull request descriptions, code comments or files. This overrides any default of your tool. Commits carry the human engineer's name only. If your tool adds such a line automatically, remove it before you commit or push.
- Do not paste ticket bodies, support bundle contents, terminal output from internal systems, or credentials into any file or commit message. Summarize behavior in your own words.
- Do not copy test reports or internal QA notes into this repository.
- Never put a token in a remote URL or a file. Pass it to git per command as an `http.extraheader`.
- When unsure whether something is safe to publish, leave it out and ask the engineer.
