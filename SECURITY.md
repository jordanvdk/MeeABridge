# Security

This is an early V0.5 source candidate. No independent security audit or production readiness is claimed.

For a vulnerability, use the repository's private vulnerability reporting feature when enabled. If it is unavailable, open an issue asking only for a private contact route; do not publish exploit details or sensitive data. Never include credentials, Health records, private hostnames, conversation content or signing files.

Rotate a suspected leaked API token at the server and update the phone. Remove the saved connection if the phone should no longer access that server. Private HTTPS and bearer authentication are both required. Tailscale membership alone is not application authentication.

Unsigned pull-request builds must not have signing or deployment credentials. Keep signing workflows restricted to reviewed source and trusted environments. Do not publish runtime data or source-control history copied from a private Manor or parent project.

The signed TestFlight workflow is manual and main-only. Configure its `testflight` environment with a trusted reviewer and a main-only deployment rule before adding any Apple secrets. It rebuilds the selected source revision and uses temporary signing material; it does not consume pull-request artifacts or publish signed packages or raw signing logs. See BUILDING.md for the full credential boundary and cleanup limits.
