# Contributing

Use synthetic fixtures only. Never include personal Health exports, tokens, server addresses, screenshots of private conversations, signing material or real runtime logs.

Keep the app small: V0.5 is manual questions and manually previewed steps snapshots. Changes to transport, permission handling, receipts or retry semantics need focused tests and a matching protocol update. Preserve null readings and never sum overlapping snapshots. Do not treat an HTTP success without a valid matching receipt as a save.

Run `swift test`, generate the project with XcodeGen, and run the unsigned simulator build described in README. Report device-only checks separately. Changes to HealthKit or Siri require real-device acceptance; simulator success alone does not establish either.

Generated Xcode projects and signing configuration stay out of Git. Use reviewed dependencies and immutable action references. Licensing contributions under MIT means you must have the right to contribute them.
