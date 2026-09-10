# V0.5 protocol

All configured remote URLs are HTTPS origins without paths, credentials, query or fragment. The client refuses redirects and sends `Authorization: Bearer <token>` in a header. The server binds to loopback; private HTTPS termination is configured separately. JSON requests are bounded to 16 KiB after encoding, including the JSON envelope and escaping, and responses to 128 KiB at the phone. Oversized encoded requests are rejected before sending.

`GET /v1/health` returns `status: "ok"`, `service: "meea"`, and a version string. It tests reachability and intentionally does not prove token validity or model health.

`POST /v1/ask` takes `question` (nonempty, <=8192 UTF-8 bytes), `source` (`manual` or `siri`) and `conversation_id: null`. The response contains `answer`, `conversation_id`, `sources` and `error`. Continuation is not supported. The phone never automatically resubmits a question after a timeout.

`POST /v1/imports/apple-health/steps` takes this synthetic example:

```json
{"schema_version":1,"import_id":"00000000-0000-4000-8000-000000000001","captured_at":"2025-01-03T00:00:00Z","time_zone":"UTC","days":[{"day":"2025-01-01","start":"2025-01-01T00:00:00Z","end":"2025-01-02T00:00:00Z","count":1234},{"day":"2025-01-02","start":"2025-01-02T00:00:00Z","end":"2025-01-03T00:00:00Z","count":null}]}
```

There are 1–7 consecutive completed civil days in the stated timezone. The app previews seven; interval bounds are UTC second-precision timestamps. Counts are finite 0–200000 or null. At least one reading must be available. The HTTP boundary checks the real timezone and midnight/day agreement, including DST. Unknown fields, client paths and arbitrary RPCs are rejected.

The adapter invokes only `imports.apple-health.steps` through the authenticated current-user MeeA client connection. The host holds its engine lock and uses the configured Manor, never a client-supplied filesystem path. It stores a bounded immutable source using create-only atomic publication, then reads it back before issuing a receipt. An older host without this capability returns an unsupported-import failure.

The receipt includes `import_id`, `status` (`stored` or `unchanged`), `stored_days` (days with a non-null count), and a Manor-relative `path` and content `hash`. `unchanged` means the same ID and same canonical payload already exist and were measured again. Reusing an ID with changed/edited content fails. A lost reply can be retried using the same preview/ID. Import IDs are not daily counters. New previews produce new immutable snapshots; later consumers must choose observations explicitly and must not sum overlaps.

The host allows up to 128 imported snapshots in the target directory, each <=16 KiB, with a bounded directory scan. It rejects new imports at quota rather than silently evicting personal content. Removing/archiving a source removes its deduplication evidence: an old ID can then be imported anew.

V0.5 does not merge days, delete earlier readings, or infer zero from missing permission/data. HTTP error text is mapped to safe app messages; internal host error bodies are not spoken or logged.
