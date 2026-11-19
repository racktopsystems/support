## What changes and why

## Publishing checklist

- [ ] `scripts/check-publish.sh` passes
- [ ] No secrets, customer data, serial numbers, or internal hostnames/addresses
- [ ] No internal ticket keys, internal URLs, or test-report details
- [ ] README follows `templates/CUSTOMER-README.md` and states supported versions and how to undo
- [ ] `SHA256SUMS` regenerated (`scripts/update-checksums.sh <directory>`)
- [ ] No AI-tool attribution in commits or PR text (no `Co-Authored-By` trailer, no "Generated with" footer)
- [ ] A second RackTop engineer has reviewed the diff
