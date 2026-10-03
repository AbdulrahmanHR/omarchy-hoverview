# Hoverview for Omarchy

An [Omarchy](https://omarchy.org) 4 (Quattro) bar widget that replaces the
workspace numbers. Hover a number to get a live, to-scale picture of that
workspace without switching to it.

<!-- Add a screenshot of the hover card as preview.png in the repository root. -->

## What it does

- **Only workspaces that matter.** Shows workspaces 1–10 that have windows,
  plus the one you're on. You can also keep 1 to N always visible. The
  focused workspace gets an accent pill.
- **Live hover preview.** Each window is drawn where it really sits on the
  monitor, with a live capture of its contents, its icon and its title.
  Turn captures off and it draws icons and names instead.
- **Tab-aware.** For a Hyprland window group (tabs), the preview shows the
  tab that is actually on screen, not a random member of the group.
- **Window list.** The workspace's windows are listed under the preview, up
  to a limit you can set. Click a tile or a row to jump straight to that
  window.
- **Full-screen peek.** Rest the pointer on the mini screen to briefly switch
  to that workspace. Move away and you're back where you were; click to stay.
- **Multi-monitor.** Workspaces on a secondary monitor are drawn in your
  theme's magenta, or a color you pick, so you can tell screens apart at a
  glance.

Each of these can be tuned or turned off. See [Settings](#settings).

## Install

```bash
omarchy plugin add https://github.com/AbdulrahmanHR/omarchy-hoverview --enable
```

Omarchy asks before cloning, then asks where on the bar the widget goes (the
center by default). Plugins run as unsandboxed code inside the Omarchy shell,
so read the code before you enable it.

The widget replaces Omarchy's workspace numbers, so take the built-in ones
off the bar: remove the `omarchy.workspaces` entry from `bar.layout` in
`~/.config/omarchy/shell.json` (the shell reloads it on save).

If you added the plugin without enabling it:

```bash
omarchy plugin enable io.github.abdulrahmanhr.hoverview
```

## Settings

### Settings panel

Right-click any workspace number to open the settings panel. It writes to
the same `shell.json` entry described below, so changes apply right away
and show up in the file and the CLI too.

If you put the settings button somewhere else, another bar widget can embed
`SettingsPanel.qml`: load it, set its `bar` and `anchorItem` properties, and
call `open()`, `close()` or `toggle()` (it also exposes `opened`).

### shell.json and the CLI

Settings are extra keys on the widget's entry in `bar.layout` of
`~/.config/omarchy/shell.json`. The shell reloads the file on save and the
widget applies the change right away. No restart needed.

You can also set them from the command line. Add `--json` for numbers and
booleans so they're stored as real values, not strings:

```bash
omarchy bar set io.github.abdulrahmanhr.hoverview previewWidth 520 --json
omarchy bar set io.github.abdulrahmanhr.hoverview peekOnHover false --json
omarchy bar set io.github.abdulrahmanhr.hoverview secondaryMonitorColor '#89b4fa'
```

The entry in `shell.json` then looks like this:

```json
{
  "id": "io.github.abdulrahmanhr.hoverview",
  "previewWidth": 520,
  "peekOnHover": false,
  "secondaryMonitorColor": "#89b4fa"
}
```

Every setting is optional. Missing keys use the defaults below. Numbers
outside the range are clamped, and invalid values fall back to the default.

| Setting | Default | What it does |
|---|---|---|
| `persistentWorkspaces` | `0` | Always show workspaces 1 to N, even when empty. `0` shows only workspaces with windows plus the one you're on. Whole number, 0–10. |
| `labelVerticalOffset` | `0` | Nudges the workspace numbers up (negative) or down (positive) for fonts that sit off-center. -10 to 10, in steps of 0.5. |
| `colorSecondaryMonitor` | `true` | Tint workspaces that live on a secondary monitor (Hyprland monitor id above 0). |
| `secondaryMonitorColor` | `""` | Hex color for that tint, `#RRGGBB` or `#AARRGGBB`. Empty uses your theme's magenta (then purple, orange, yellow). |
| `preview` | `true` | Show the hover card. Off turns the widget into plain workspace numbers. |
| `hoverDelayMs` | `220` | How long to hover before the card opens. Milliseconds, 0–2000. |
| `previewWidth` | `420` | Width of the preview, before UI scaling. Pixels, 240–800. |
| `livePreview` | `true` | Live captures of window contents. Off draws app icons and names instead, which is lighter on the GPU. |
| `showWindowList` | `true` | Show the list of windows under the preview. |
| `maxListedWindows` | `6` | How many windows the list shows before "+ N more windows". 1–20. |
| `highlightLastFocused` | `true` | Highlight the window you used last on the hovered workspace. Off highlights only the window that has focus right now. |
| `peekOnHover` | `true` | Rest the pointer on the preview to briefly switch to that workspace. |
| `peekDelayMs` | `180` | How long to rest on the preview before peeking. Milliseconds, 0–2000. |

## Requirements

- Omarchy 4 with the Quickshell-based `omarchy-shell`
- Hyprland 0.56 or newer (uses the Lua dispatcher syntax and the `visible`
  field of `hyprctl clients` to find the shown tab of a group)

There are no other dependencies. The widget reads window data with
`hyprctl -j clients` when you hover, and reads theme colors from
`~/.local/state/omarchy/current/theme/colors.toml`. The only configuration
it changes is its own `shell.json` entry, through `omarchy bar set`, when you
use the settings panel.

## Remove

```bash
omarchy plugin remove io.github.abdulrahmanhr.hoverview
```

Then put Omarchy's own workspace numbers back on the bar if you want them:

```bash
omarchy bar put omarchy.workspaces --section center
```

## License

[MIT](LICENSE)
