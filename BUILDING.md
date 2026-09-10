# Building and distribution

The initial local candidate has not been compiled with Xcode. The first macOS run must pass both Swift package tests and an unsigned simulator build; fix any compiler, signing-metadata or AppIntent extraction errors before claiming build readiness.

## Unsigned CI

`.github/workflows/unsigned.yml` uses hosted macOS, pinned action commits and a checksum-verified XcodeGen release. It has read-only repository permissions, no signing secrets and no self-hosted runner. Pull requests may run these unsigned checks. No `pull_request_target` or privileged follow-on workflow is provided.

The simulator ZIP contains only the built app. It is useful for inspection and simulator testing, not iPhone installation. Do not add Health exports, live configuration, tokens or runtime logs to build inputs or uploaded artifacts.

## Device/TestFlight setup

1. Complete Apple Developer enrollment and create an explicit app identifier with HealthKit enabled.
2. Replace the placeholder bundle identifier in `project.yml` with the identifier you own. Keep team IDs and signing settings in an ignored local configuration or the trusted signing environment.
3. Generate the Xcode project and configure the correct signing team, certificates and provisioning profile. Verify the read-only HealthKit entitlement and usage description.
4. Build and archive on macOS with Xcode, then validate/export and upload through Apple's supported tools. Configure App Store Connect and TestFlight access. A signed archive alone is not a TestFlight installation.
5. Complete the actual device checks in `docs/acceptance.md` before distributing more broadly. Review Apple privacy disclosures, encryption compliance, HealthKit policy and any required privacy manifest against the final binary and distribution configuration.

A future signing workflow must be separate and manually dispatched from a reviewed trusted branch/ref. Gate it with a protected environment. Never expose signing or App Store Connect secrets to pull-request code, fork workflows or untrusted artifacts. Build the reviewed source again in the signing job; do not sign arbitrary artifacts produced by an untrusted job. Use a temporary keychain and remove signing material afterward.

No signing workflow or account credentials are included in V0.5. No Apple purchase, repository publication, TestFlight upload or private network setup occurs merely by creating this source.

Primary references: [Xcode](https://developer.apple.com/xcode/), [TestFlight](https://developer.apple.com/testflight/), [HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data), [XcodeGen](https://github.com/yonaskolb/XcodeGen).
