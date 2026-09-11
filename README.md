# MeeA Bridge

A small native iPhone companion for your own MeeA server. Ask a question in the app or through an Ask MeeA App Intent, and preview then manually send seven completed days of Apple Health step totals.

**V0.5 source candidate.** [The first macOS CI run](https://github.com/jordanvdk/MeeABridge/actions/runs/34539302664) passed all seven core tests and built the unsigned iOS simulator app with Xcode 16.4. Signed installation, Siri and real HealthKit acceptance are still pending. The server needs the matching steps-import capability before Sync Health can succeed.

## What is included

- SwiftUI connection settings, manual Ask and safe error messages.
- HTTPS-only transport, no redirects, bounded replies and timeouts.
- API token in this device's Keychain, available only while unlocked, with no iCloud synchronization.
- Ask MeeA action for Shortcuts/Siri, requiring device authentication.
- Read-only step-count permission request, seven-day preview and explicit Sync Health.
- Stable import ID for retries of the current preview. No automatic upload or background delivery.

The phone does not host the agent or copy the Manor. A question goes to the configured server and its configured model provider. Health sync sends structured aggregates to the server's import endpoint without an LLM prompt.

## Build

Requires macOS, Xcode 26.6 and XcodeGen 2.46.0. The app supports iOS 17 and later. The GitHub Actions workflow runs unsigned checks on pushes and pull requests; it uses no signing secrets.

```sh
swift test
swift scripts/GenerateAppIcon.swift
xcodegen generate
xcodebuild -project MeeABridge.xcodeproj -scheme MeeABridge \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

A separate manually dispatched workflow can sign and upload to internal TestFlight after configuring the protected environment and Apple signing inputs.

The simulator artifact is **not installable on an iPhone**. See [BUILDING.md](BUILDING.md) for the signed device/TestFlight path. No paid service is required to inspect this source; device distribution has separate Apple requirements.

## Connect and use

1. Run the matching MeeA bridge on your PC, bound to loopback. Configure private HTTPS access, for example Tailscale Serve within your tailnet. Do not expose an unauthenticated public port.
2. Enter its HTTPS origin and bearer token in MeeA Bridge, then Save connection. Test connection checks server reachability; Ask additionally verifies the token and agent.
3. Ask a short question manually first. Once that succeeds, find Ask MeeA in Shortcuts and invoke it with a question. A timeout may leave the accepted question running; Ask is never automatically retried.
4. Request read access to steps, then Preview. Apple does not reveal whether empty read results mean denied permission or absent data. Unavailable is never converted to zero.
5. Review the dates, timezone and totals, then tap Sync Health. A save is confirmed only after a matching server receipt. If the result is uncertain, retry the same preview.

Previews live only in memory. Closing the app loses that preview's retry ID; a new preview creates a distinct immutable snapshot. The V0.5 store retains snapshots as source records, not additive counters. **Never sum overlapping snapshots.** Newer readings can differ from earlier ones; V0.5 does not merge corrections or propagate HealthKit deletions. No daily dashboard or query tool is included yet.

Read [PRIVACY.md](PRIVACY.md), [the protocol](docs/protocol.md), [the roadmap](docs/roadmap.md), and [the device acceptance checklist](docs/acceptance.md).

## License

MIT. See [LICENSE](LICENSE). This is an independent companion, not an Apple product.
