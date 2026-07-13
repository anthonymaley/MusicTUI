# AirPlay Robustness — Phase 1: Play-Time Verify-and-Heal

**Date:** 2026-07-11
**Status:** Approved design (all four sections user-approved in session)
**Decision trail:** Q4 answered = branch A (spike-first, then tiered heal). Spike ran live on macOS 26.4.1 / Music 1.6.4 before this design was written; every claim below carries its evidence.

## Problem

AirPlay routing through Music's scripting interface fails in three user-confirmed modes:

- **(A) Ghost at selection** — speaker shows selected, no audio plays on it.
- **(B) Ghost after idle/sleep** — HomePod that slept accepts selection but never carries audio.
- **(C) Route reverts** — playback falls back to the laptop; the route won't persist.

All three share one root: the AirPlay *session* never durably establishes (or silently dies), while the scripting layer keeps claiming the route is fine. The user's reliable manual fix is clicking Music's own AirPlay popover and deselecting/reselecting the device.

Goal: every route operation ends either **verified with evidence** or in an **honest failure that names the manual fix** — never "selected and hoped." Phase 1 is play-time only (no daemon); Phase 2 (continuous guardian) is a separate later spec.

## Spike evidence (2026-07-11, live)

### Signal truth table

| Signal | Verdict | Evidence |
|---|---|---|
| `selected` of AirPlay device | False positives | Ghosts show `selected:true` with no audio (user-confirmed history) |
| `active` of AirPlay device | Event-latched; false negatives | Kitchen audibly played 8s with `active:false` (route had been set while paused). Flipped true on 3/3 *mid-play* establishes |
| `current AirPlay devices` | Can wedge permanently | Read `[Kitchen]` correctly early in session; after one route-while-paused it read **empty** and stayed empty through every subsequent write, including clean mid-play reroutes that sel/act/network all confirmed |
| `network address` property | Useless for identification | Returns a MAC absent from both ARP and NDP tables (not the device's Wi-Fi MAC). Kitchen's real IP found via mDNS: `kitchen.local → 192.168.1.112` (matches flow evidence) |
| **Established TCP connections to device IP** | **Never lied in any experiment** | Fresh `:7000` + data-port connections appeared ≤1s after every real establish; full teardown on route-away; unaffected by scripting-layer wedges |

Key systemic observation: **both scripting-state corruptions were triggered by route-while-paused; all three mid-play routes registered consistently.** The Mac also holds *standing* control connections to `:7000` of every AirPlay device on the LAN, so connection *presence* is not the signal — **churn** (delta across a route operation) is, with a fresh-session fingerprint (second `:7000` conn + new high-port data conns on HomePods) as the steady-state check.

### Heal-write evidence

| Write | Effect on live broken state |
|---|---|
| Re-issue `set selected … to true` | No-op (state unchanged) |
| List-write same device | No-op, zero network churn |
| **List-write away-and-back, mid-play** | **Moved the session for real**: old device's connections torn down, new device's established, `active` latched true |

### UI-script tier

macOS 26's redesigned Music exposes **no player chrome** (AirPlay button, transport, volume) in the main window's accessibility tree — frontmost or not, `AXEnhancedUserInterface` or not. The MiniPlayer *does* expose an `airplay` button, but its reveal is hover-state-dependent and was not reproducibly triggerable (3 attempts: fresh-open timing, key-window raise, synthetic pointer-enter). **The design must not depend on UI scripting the popover.** It remains the documented *manual* fallback in the honest-failure message. (Accessibility permission itself is granted and menu clicks need no focus steal — the blocker is the AX tree, not permissions.)

## Design

### Components

**`RouteVerifier`** (`tools/music/Sources/Backends/RouteVerifier.swift`) — the truth oracle.

- **Name → IP:** resolve `<name>.local` via mDNS; fall back to browsing `_airplay._tcp` and matching the service instance name (instance names ≠ hostnames in general). Never use the `network address` property.
- **Read the TCP table** (netstat-equivalent) and report established connections to the device's IP.
- **Two modes:**
  - *Delta sampling* (route operations): snapshot before, snapshot after, verdict from churn. Establishment observed ≤1s in all spike runs; poll up to a ~5s timeout.
  - *Steady-state check* (`speaker verify`): classify current connections against the standing-control baseline (fresh-session fingerprint: additional `:7000` connection + high-port data connections).
- Scripting read-backs (`selected`, `active`) are collected as *advisory* context for reporting, never as the verdict. `active` latching true after a mid-play establish is a supporting confirm (3/3 in spike).

**`RouteHealer`** (`tools/music/Sources/Backends/RouteHealer.swift`) — the escalation ladder below, each tier followed by re-verify.

### The ordering rule (from evidence)

Routing issued while paused is never **trusted** — it was the corruption trigger in 2/2 observed scripting-state corruptions, cannot be network-verified (no flows to observe), and prevents the `active` latch. It may still be **issued** before playback starts (as today — this avoids audio briefly playing on the wrong device), but all verification and any corrective re-assertion happen **after playback starts**. The play path runs: **route (untrusted) → start playback → verify → heal (mid-play) → re-verify → honest failure**, preserving the parameter-error-50 rule (routing and playback in separate osascript calls).

### Heal ladder

1. **Tier 1 — away-and-back:** list-write route to the computer device, then back to the target, while playing. (The programmatic equivalent of the user's manual popover fix; the only write that demonstrably moved a live session in the spike.)
2. **Tier 2 — full reset:** the same away-and-back bracketed by a playback stop/start cycle. Untested in the spike; distinct from tier 1 by the transport cycle. The implementation plan must validate it in its live-probe step before relying on it.
3. **Tier 3 — honest failure:** stop retrying. Print exactly what's known and what to do, e.g.:
   > Route to Kitchen NOT verified: selection accepted but no session traffic after 2 heal attempts.
   > Manual fix that works: click the AirPlay icon in Music, deselect and reselect Kitchen.
   > (network: no session connections to 192.168.1.112 · scripting claims: selected=true active=false)

Dropped with evidence: `set selected` re-issue, list-write-same-device, UI-script tier.

### CLI surface

- **`music speaker verify [name]`** — new verb, read-only steady-state verdict with evidence. No argument: verify whatever is currently claimed as routed.
- **Play path** (`music play …` with named speakers): verify-and-heal runs automatically; success output gains one word (`routed to Kitchen ✓ verified`). No new flags.
- **`music speaker set/add/remove`:** while playing → full verify-and-heal; while paused → route and print a deferral note ("route set; will verify on next play").
- **`music speaker wake`:** upgraded from blind reset to verify-first — heal only what's broken, report findings.
- **TUI `SpeakersScene`** toggles call the same backend function as the CLI — one implementation, both surfaces.
- Docs travel with code: `skills/music/SKILL.md`, `README.md`, `docs/guide.md` updated in the same commits.

## Testing

- **Unit (CI-safe):** TCP-table parser and connection-classifier tested against fixtures captured in the spike (routed / unrouted / wedged states for Kitchen and Master). Bonjour resolver behind a protocol seam for injection. Suite stays hermetic (158 green today).
- **Live probes (gated, this Mac):** route to a real speaker at low volume, assert establishment detected within timeout; route away, assert teardown detected. Repeatable "probe every write."
- **Ghost capture protocol (not a test):** ghosts don't reproduce on demand (an idle HomePod established in ~1s in the spike). When one next occurs naturally, `music speaker verify` dumps the network verdict plus all scripting claims — capturing the ghost's fingerprint to confirm the core assumption (*ghost = no data connections*). Until then that assumption is **tested by proxy, not verified**.
- **Acceptance:** every route operation ends in `verified`-with-evidence or tier-3 honest failure.

## Out of scope (Phase 1)

- Phase 2 continuous guardian (daemon/watcher).
- Multi-room group verification beyond the single-target case (grouped routing keeps working as today; verification of *each* group member is a natural Phase 2 extension).
- UI-scripting the AirPlay popover.

## Open questions (carried to the plan)

1. Is the `current AirPlay devices` wedge Music-process-scoped? Check at the next natural Music restart; do not force-restart the user's queue.
2. Per-device-class "routed" connection fingerprint: HomePod verified; TVs / Sonos / Apple TV untested — the live-probe step should capture one of each available class.
3. Real-ghost fingerprint (see capture protocol above).
4. TCP-table read mechanism in Swift: shell out to `netstat -an` (spike-proven) vs. `libproc`/`sysctl` native read — implementer's choice; parser must be fixture-tested either way.
