# Roadmap

| Version | Scope |
| --- | --- |
| V0 | Ask MeeA AppIntent and private connectivity through Tailscale |
| V0.5 | HealthKit permissions and manual steps preview/sync |
| V1 | Incremental HealthKit sync and a dedicated health time-series store |
| V1.5 | Manor summaries/trends and MeeA health query tools |
| V2 | Background delivery and automatic sync |

The initial V0.5 is a source candidate, pending macOS build and phone acceptance. It has no background HealthKit entitlement, observer delivery or incremental anchor. The later store must handle revisions, deletions, timezone changes and duplicate delivery before summaries or automation depend on it.
