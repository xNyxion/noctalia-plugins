# IDEA.md — Noctalia Plugins by Nyx

Source of truth for what this repository is and is for. Read this before
adding a plugin, changing scope, or publishing. `README.md` covers usage
mechanics; this file covers intent.

## What this repo is

A Noctalia v5 plugin **source repo**: one directory per plugin, each a
self-contained `plugin.toml` + Luau entry scripts, indexed by the root
`catalog.toml` so a Noctalia host can list/install without cloning
everything. Installable as a local `path` source (hot-reloads `.luau` on
edit) or as a `git` source pointing at this repo.

## Scope — what belongs here

- Personal, single-purpose Noctalia v5 plugins for daily desktop use: bar
  widgets, click-out panels, background services (`[[widget]]`,
  `[[panel]]`, `[[service]]`, `[[shortcut]]`, `[[launcher_provider]]`,
  `[[desktop_widget]]` entries).
- v5 only. v4/Quickshell-based plugins are dead; do not port or reference
  that model.
- Each plugin should do ONE thing and use the **lowest** `plugin_api` level
  that covers its actual capabilities — raising it drops every Noctalia
  install below that level.

## Out of scope

- Not a general app platform or plugin framework — no shared runtime, no
  cross-plugin abstraction layer speculatively added for "future" plugins.
  A shared pattern gets extracted only once two real plugins need it, not
  before.
- Not a fork or distribution channel for other authors' plugins.
- No secrets, tokens, or user-specific config committed to plugin sources.

## Repository structure (authoritative)

```
noctalia-plugins/
├── IDEA.md          # this file — repo intent/scope, read first
├── README.md        # usage: adding as a source, conventions, install
├── catalog.toml      # indexes every plugin; mirrors each plugin.toml
└── <plugin-dir>/     # named after the id segment after "/" (nyx/radio-player -> radio-player/)
    ├── plugin.toml
    ├── *.luau
    ├── translations/en.json   # required once any setting or noctalia.tr() exists
    └── AGENTS.md      # plugin-specific bugs/decisions for future work — required per plugin
```

Naming and layout in `README.md` are load-bearing: both the `path` source
loader and `catalog.toml` expect the directory name to match the id suffix.

## Conventions (see README.md for detail)

- `catalog.toml` rows and each plugin's `plugin.toml` must carry the same
  version — the store reads the catalog, the runtime reads the manifest.
- Non-obvious behavior and past bugs go in that plugin's `AGENTS.md`, not
  commit messages or this file.
- Follow the `noctalia-plugin-dev` skill (or
  https://docs.noctalia.dev/noctalia/plugins/development/) for manifest
  shape, entry lifecycle, and the declarative UI API — do not guess Luau
  API signatures.

## Current state

One shipped plugin:

| Plugin | id | Requires | Status |
|---|---|---|---|
| Radio Player | `nyx/radio-player` | `mpv` | Live, v2.0.0, verified per its AGENTS.md |

## Backlog

Candidate plugins land here before a directory exists for them. Move an
entry into its own `AGENTS.md` once work starts; delete it from this list
once shipped.

- (none open — add candidate ideas here as they come up)

## For agents and subagents working in this repo

- This file is the scope authority: if a request would add a plugin or
  capability outside "Scope" above, or introduce a shared framework flagged
  "Out of scope", say so and ask before building it.
- Read the target plugin's own `AGENTS.md` before touching its process
  management, state sharing, or persistence — each documents bugs already
  found and fixed once.
- Keep `catalog.toml` and `plugin.toml` versions in sync in the same change
  that bumps either.
