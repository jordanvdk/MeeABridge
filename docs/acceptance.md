# Device acceptance — pending

Do not mark these checked until performed against the exact signed candidate and matching installed server.

- [ ] Swift package tests and unsigned simulator build pass on macOS.
- [ ] Signed app installs on a real iPhone and launches; HealthKit entitlement is present.
- [ ] Save, relaunch and remove connection exercise Keychain behavior; wrong token fails safely.
- [ ] Private HTTPS reaches only the configured server; unreachable PC and timeouts produce useful errors.
- [ ] Manual Ask receives the correct agent reply; unrelated or late replies are not substituted.
- [ ] Ask MeeA works through Shortcuts and Siri, prompts for question as needed and enforces authentication.
- [ ] First Health request asks for read-only steps, with no write/sleep/heart-rate access.
- [ ] Denial, partial permission, revocation and empty Health data show unavailable without fabricating zero.
- [ ] Preview matches Apple Health across seven completed local days, including phone/watch overlap.
- [ ] Check DST, current-timezone changes, partial data and delayed source corrections.
- [ ] Preview alone sends no Health payload. Sync sends only the reviewed snapshot.
- [ ] The matching host receipt names an actual inspectable Manor file with the expected days/nulls.
- [ ] Retry after a lost response verifies the same import/file without a duplicate. Conflicting ID fails without overwrite.
- [ ] New preview/relaunch behavior is understood: a new snapshot, not an additive daily count.
- [ ] Old host, server quota/storage failure and malformed receipts never show a confirmed save.
- [ ] Revoke Health permission and remove connection; confirm no automatic future uploads.

Use private test evidence locally. Only synthetic fixtures belong in the repository or CI artifacts.
