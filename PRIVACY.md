# Privacy and data flow

MeeA Bridge is a client for a server you configure. It has no developer-operated account system, advertising, analytics or crash-reporting SDK.

## On the phone

The saved HTTPS server origin and bearer token are one Keychain item, restricted to this device and available only while unlocked. They are not synchronized through iCloud. A blank token field retains the saved token only for the same HTTPS origin (host and effective port); changing servers requires explicitly entering a token. The token is not stored in project settings, URLs, logs or UserDefaults. Remove connection deletes this item; deleting an app may leave Keychain items, so use Remove connection before uninstalling when you want to remove credentials.

Questions, answers, step previews and import receipts remain in memory. They are not intentionally written to files by the app. The app hides its content when inactive. Operating-system features such as Siri, screenshots and Shortcuts can handle or retain displayed/spoken content under their own settings. Siri receives your question and the spoken reply; the intent requires authentication.

Only `stepCount` read access is requested. The app requests no HealthKit write permissions. Authorization-sheet completion does not prove read access. Empty results may mean denied access or no readings; the app says Unavailable. Manage or revoke permission in Apple Health.

## What leaves the device

- Ask sends the question and a source label to the saved HTTPS server. The server runs your configured agent/model; its provider and retention settings determine further processing. Replies may contain private Manor context.
- Sync Health sends an import UUID, schema version, capture time, current timezone, date/interval boundaries and available daily step totals for seven completed days. Missing readings are explicit nulls. No raw samples, device/source IDs, HealthKit UUIDs, incremental anchors, sleep or heart-rate records are sent.
- Both use bearer authentication. HTTP redirects are refused. There is no automatic upload, background sync or automatic retry. Test connection contacts the server's health route.

## On the server

The matching MeeA host saves one immutable JSON source file in the Manor's hearth and returns its path/hash. An identical import-ID retry verifies that file; a changed payload using the same ID is rejected. Original or manually edited files are never overwritten. Imported records count toward a bounded snapshot quota; exceeding it requires local review/archive, not silent deletion.

Snapshots can overlap. They are observations, not counters to add together. A new preview is a new snapshot even if its readings are unchanged. V0.5 does not process HealthKit deletions, merge corrections, make trends, or automatically give health data to an LLM. Saved files are part of the Manor and can be read by the user's configured agent when they choose to use that context.

The matching bridge's diagnostic log excludes questions, answers, tokens and health readings. Its separate private recovery receipts may retain agent answers and notices. PC/Manor backups may retain imported health data. Removing the phone connection or revoking Health access does not delete server records; review/delete those files and backups separately on the PC. Do not upload them to GitHub or a bug report.
