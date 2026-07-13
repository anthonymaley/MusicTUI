# Deferred & Future Context

Forward-looking notes rescued during trim passes. Check this file when starting
new features — items here may affect design or unblock work.

## AirPlay robustness (from 2026-07-11-airplay-robustness-design.md)

Explicitly out of scope for the shipped Phase 1, deferred to a future Phase 2:

- **Continuous guardian (daemon/watcher)** — Phase 1 is play-time verification
  only; a resident process that watches routes continuously was named as a
  separate later spec.
- **Multi-room group verification beyond the single-target case** — grouped
  routing works as before, but verifying *each* group member individually was
  called out as a natural Phase 2 extension.

## Library tab (from 2026-07-11-library-tab.md)

- **On-disk albums cache** (`~/.config/music/library-albums.json`) was noted as
  a fast-follow to the off-thread fetch. Since then the stale-while-revalidate
  pattern shipped for artist tiers (`artist-tiers.json`, 3.4.0) — an albums-list
  cache would reuse that proven shape.
