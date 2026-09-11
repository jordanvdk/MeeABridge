# Building and TestFlight distribution

The initial V0.5 source passed seven Swift tests and an unsigned simulator build. Current workflows explicitly use Xcode 26.6 on the standard GitHub-hosted `macos-26` runner to meet Apple's current upload requirements. An unsigned build does not prove signed installation, Siri behavior or real HealthKit access.

## Local and unsigned builds

On a Mac with Xcode 26.6 and XcodeGen 2.46.0:

```sh
swift test
python3 -m unittest discover -s scripts/tests
swift scripts/GenerateAppIcon.swift
xcodegen generate
xcodebuild -project MeeABridge.xcodeproj -scheme MeeABridge \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

The icon is rendered from a small checked-in vector drawing program. Its generated opaque PNG is ignored by Git. The app includes its privacy manifest; review it again when adding SDKs or required-reason APIs.

`.github/workflows/unsigned.yml` runs tests and an unsigned simulator build on pushes and pull requests. It uses read-only repository permissions, a pinned checkout action and checksum-verified XcodeGen. No signing secrets, privileged follow-on workflow or self-hosted runner are used. Its simulator ZIP is **not installable on an iPhone**.

## One-time Apple setup

1. Activate Apple Developer Program membership and accept any required agreements in your own account.
2. As Account Holder/Admin, register an explicit bundle identifier and enable HealthKit. Create the matching iOS app record in App Store Connect.
3. Create an Apple Distribution certificate from a privately generated CSR. Export the certificate and its matching private key as a password-protected P12. Windows users can generate the CSR/private key with standard cryptographic tools; a Mac is not required for this preparation.
4. Create an App Store Connect distribution provisioning profile for the exact app identifier and certificate. Download the profile. Development, ad hoc, enterprise and wildcard profiles are not accepted by this workflow.
5. Create a dedicated App Store Connect team API key. Developer access suffices for uploading; App Manager can also manage TestFlight metadata. Initial distribution certificate, App ID and profile setup needs Account Holder/Admin access. Keep setup credentials separate from the ongoing upload key.

Do not put private keys, profiles, certificates, export settings, personal Health data or local runtime configuration into Git or chat. Upload secrets directly to the protected GitHub environment from their private local files or GitHub's secret-entry UI.

## GitHub environment

Create an environment named `testflight` before dispatching the signed workflow. Restrict it to the `main` branch, require a trusted owner/reviewer, and disable administrator bypass. A solo owner may allow self-review so they can approve their own manually started run. Keep all Apple credentials at the environment level, not in repository-wide secrets. Forks must configure their own environment and signing identity.

| Environment setting | Contents |
| --- | --- |
| Variable `APP_BUNDLE_ID` | Registered explicit bundle identifier |
| Secret `APPLE_TEAM_ID` | Apple Developer team identifier |
| Secret `APPLE_DISTRIBUTION_P12_BASE64` | Base64 of the encrypted distribution P12 |
| Secret `APPLE_DISTRIBUTION_P12_PASSWORD` | P12 password |
| Secret `APPLE_PROVISIONING_PROFILE_BASE64` | Base64 of the App Store distribution profile |
| Secret `ASC_KEY_ID` | Upload API key identifier |
| Secret `ASC_ISSUER_ID` | Upload API key issuer UUID |
| Secret `ASC_PRIVATE_KEY` | Complete PKCS8 `.p8` upload key text |

The public project keeps a placeholder bundle identifier and no team identity. The signing job applies the environment's registered identity to the device archive. Release signing settings are scoped to the app target through custom `MEEA_*` build variables so provisioning profiles are not applied to Swift package targets. GitHub environment settings and secrets are not created by cloning this repository.

## Run a signed build

Open Actions → Signed TestFlight upload → Run workflow. Select `main` and leave upload enabled to validate and upload to Apple. Review the selected revision before approving the environment. Setting upload to false verifies signing and export only; it publishes no installable artifact and does not need the three ASC secrets.

The workflow checks out the dispatch SHA, reruns tests, regenerates the icon/project, validates the profile's team/app/expiry/HealthKit/distribution type, and matches the P12 identity to the profile. It creates a temporary keychain, archives the iPhone app, checks its signature and entitlements, and exports an **internal-TestFlight-only** package. The build number is the workflow run number plus run attempt, for example `3.1`. Each new dispatch advances it; re-running an older historical run is not a way to replace a newer uploaded build.

Apple validation and upload use API-key authentication. No automatic provisioning changes, Apple password, signing action from a pull request, untrusted artifact signing or automatic App Store release are included. Upload is manual and restricted to `main`; branch access and the environment review gate are configured separately in GitHub.

Signing commands keep raw diagnostic output private on the ephemeral runner. Only fixed stage/error messages, allowlisted failure categories, standard Info.plist key names and bounded Apple ITMS error codes are published; account/app values and raw log text are never included. The job uploads no IPA, archive, signing material or raw signing log as a GitHub artifact. Cleanup runs on success/failure and in a final workflow step; forced runner termination ultimately relies on GitHub discarding the hosted runner. Signed apps inherently contain their public signing identity and provisioning information, so do not treat a distributed app as anonymous.

## After upload

An accepted upload is not yet an installable TestFlight build. Wait for Apple's processing, resolve any reported compliance/metadata issues, create an internal testing group and add your own App Store Connect user. Assign the processed build to that group, then accept it in TestFlight on the phone. No other testers are invited by this workflow.

Complete `docs/acceptance.md` on a real iPhone. The matching MeeA backend and private HTTPS connection must also work before Ask or Sync Health can succeed. Installing through TestFlight alone does not configure the server or Tailscale.

Primary references: [Apple upload requirements](https://developer.apple.com/news/upcoming-requirements/), [upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/), [internal TestFlight testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/), [App Store profiles](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/), [API keys](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).
