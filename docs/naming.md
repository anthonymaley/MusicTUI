# Naming Decision

## Summary

Use one primary public name and one command namespace:

- **Marketplace / display name:** `Apple Music`
- **Repo / README title:** `Apple Music for Claude Code`
- **Slash command namespace:** `/music:`
- **CLI binary:** `music`
- **Skill name:** `music`

Do not expose a second public brand like `ceol` in the main product surface.

## Review Points

These are the review conclusions that drove this decision:

- The product was teaching too many names for one thing: `music` for the plugin, `ceol` for the CLI, and `ceol` again for the skill.
- `ceol` was described as internal, but the docs still required users to know it for install, auth, config paths, and architecture.
- `music` is a strong command namespace, but too generic as the only marketplace-facing product name.
- The command vocabulary was drifting between terse aliases and descriptive names without a clear naming rule.

In short:

- discovery needed more clarity
- daily usage needed less naming overhead
- command naming needed one consistent rule

## Why

The product needs to be easy to find, understand, and use.

- `Apple Music` is clear and searchable in marketplaces.
- `/music:` is short and easy to type.
- `music` is a simple CLI name for direct terminal use.
- Reusing the same name across plugin, skill, and CLI reduces cognitive load.

The key rule is:

> Public discovery should optimize for clarity. Daily usage should optimize for speed.

That means `Apple Music` for listings and docs, and `music` for commands.

## Decision

### 1. Public naming

Use `Apple Music` as the public-facing product name in:

- marketplace metadata
- README title/subtitle
- guide docs
- descriptions and install docs

`music` is the command namespace, not the only product name.

### 2. Slash commands

Keep the slash namespace as:

```text
/music:play
/music:pause
/music:stop
/music:search
/music:playlist
```

These are good names because they are namespaced. `/music:play` and `/music:stop` are unlikely to conflict in practice because the `music` prefix provides the disambiguation.

Do **not** move to bare commands like:

```text
/play
/stop
```

Those are too generic and are more likely to conflict with future plugins or app-level commands.

### 3. CLI naming

Use:

```bash
music now
music search "Fouk"
music auth setup
```

Do not make users learn a second CLI brand. If `ceol` is kept at all, it should only exist as an internal codename or optional alias, not as the primary CLI name in docs or setup.

### 4. Skill naming

The skill should also be named `music` so that the product language stays consistent.

Users should not have to learn:

- one name for the plugin
- another for the CLI
- another for the skill

## Command Naming Rule

Prefer clear, searchable command names as the primary surface.

### Primary commands

Keep these as the documented commands:

- `play`
- `pause`
- `skip`
- `back`
- `stop`
- `search`
- `add`
- `playlist`
- `speaker`
- `shuffle`
- `repeat`
- `auth`

### Short forms

Short forms are acceptable as aliases, but they should not be the only documented form.

Recommended approach:

- prefer `now` as primary, allow `np` as alias
- prefer `volume` as primary, allow `vol` as alias if needed

This keeps the product easier to learn and easier to discover in command palettes and docs, while still supporting fast typing for experienced users.

## Spotify Scope

Do **not** rename this product to a provider-neutral umbrella just because Spotify may exist later.

Current decision:

- `Apple Music` remains a dedicated Apple Music plugin
- Spotify, if added later, should be a separate plugin unless there is a real multi-provider architecture

Why:

- Apple Music and Spotify have different auth models
- playback control capabilities differ
- speaker/device behavior differs
- a generic `music` marketplace brand is too broad unless the product is actually provider-agnostic

If Spotify is built later, the likely shape is:

- `Apple Music` plugin with `/music:`
- separate `Spotify` plugin with its own namespace

Only move to a shared multi-service umbrella if the product genuinely becomes cross-provider by design, not just by possibility.

## Practical Guidance

When writing docs, metadata, and UX copy:

- say `Apple Music` when describing the product
- say `/music:` when describing slash commands
- say `music` when showing terminal commands

Good examples:

```text
Apple Music for Claude Code
/music:play
music auth setup
```

Avoid mixing in a second public name for the same product.

## Working Principle

The product should feel like one thing:

- easy to discover as `Apple Music`
- easy to invoke as `/music:`
- easy to script as `music`
