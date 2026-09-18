# Noctalia Plugins by Nyx

Noctalia v5 plugins, one directory per plugin. Each directory is named after
the part of the plugin id following the `/` — `nyx/radio-player` lives in
`radio-player/` — which is what both the `path` source loader and the catalog
expect.

```
noctalia-plugins/
├── catalog.toml     # indexes every plugin for source/store listing
└── radio-player/    # nyx/radio-player
    ├── plugin.toml
    ├── *.luau
    ├── translations/en.json
    └── AGENTS.md    # plugin-specific notes for future work
```

## Plugins

| Plugin | id | Requires | Description |
|---|---|---|---|
| Radio Player | `nyx/radio-player` | `mpv` | Bar widget plus click-out panel for internet radio: play/pause, next/prev, station list. |

## Using this repo as a plugin source

As a local checkout:

```sh
noctalia msg plugins source add nyx-plugins path ~/Forge/Repositories/Nyxion/noctalia-plugins
```

Or straight from the remote:

```sh
noctalia msg plugins source add nyx-plugins git https://github.com/xNyxion/noctalia-plugins
```

Then enable what you need, e.g. `noctalia msg plugins enable nyx/radio-player`.
A `path` source reads the working tree directly, so `.luau` edits hot-reload
and manifest changes apply on the next config reload.

## Conventions

- `catalog.toml` rows mirror each plugin's own `plugin.toml`. The runtime reads
  the manifest, the store reads the catalog — keep both in step when bumping a
  version or `plugin_api`.
- Use the **lowest** `plugin_api` that covers the capabilities actually used;
  raising it drops every Noctalia below that level.
- A plugin with settings or `noctalia.tr(...)` calls needs `translations/en.json`;
  setting labels are translation keys, literal text is rejected.
- Non-obvious behaviour and past bugs belong in that plugin's `AGENTS.md`, not
  in commit messages.
