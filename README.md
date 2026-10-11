# Commuter Compass (Transport Fever 3 mod)

Adds a **Commuters** card to the town window. **Outbound** lists the towns where this town's residents work or
shop. **Inbound** lists the towns whose residents work or shop here. **Nearby, no commuters** lists the three nearest
towns with no commuters either way. Each section is the base game's sortable table: the town, its straight-line
distance, work trips, shop trips, and line usage (the share of those trips on the player's lines). The tables start
sorted by distance, and every section starts collapsed.

Each row has the game's Locate button, a clickable name that opens the town's window, and an arrow toggle. The
toggle shows one passenger-flow arrow on the map and frames both towns. The arrow is animated when line usage is
above 0, and faint otherwise. Its distance is shown on the map, at the top of the arc (on a full-screen layer of the
arrow's own map action, so popups can't displace it).

The counts come from `api.engine.util.town.getSourceToDestinationCount`, the same source as the base game's
Destinations table on the Supplies tab. They are a snapshot of residents' destinations (trips), not trips per year
and not people.

It also adds a **Waiting passengers** card to the station window: the people waiting at the station for the player's
lines, grouped by their final destination (the town, or industry, that their trip ends in). There's one row per
destination and line, with the straight-line distance, the number of people and the line (which opens the line's
window). The card starts collapsed, showing only the totals ("142 people · 12 destinations"), because the base
window puts plugin cards above the Terminals list; clicking the totals opens the table. The card recounts every 2 seconds while the window is open. The numbers update in place, and the order only
changes when you click a header, so the window doesn't jump around. Each row's arrow toggle shows a flow arrow from
the station to the destination.

The waiting people come from `simEntityAtTerminalSystem.getLineStopSimEntities` for each of the station's line stops.
Each person's `SIM_PERSON.targetOrAtEntity` is a town building, and `TOWN_BUILDING.town` gives the town.

- Mod ID: `pgrace_commuter_compass`
- Cosmetic: yes. It doesn't affect the simulation, so achievements stay enabled.
- Design: [docs/superpowers/specs/2026-10-09-commuter-compass-design.md](docs/superpowers/specs/2026-10-09-commuter-compass-design.md)
- Sibling: Cargo Compass (`../closest_consumer`)

Agent and modding notes for all mods live in `../AGENTS.md`.

## Layout

```
mod/pgrace_commuter_compass/          # the mod folder TF3 loads
├── mod.json, _metadata/              # modinfo.json, description.html, screenshots
├── tealdef/                          # Teal type definitions (canonical; build.py mirrors them into content/)
└── content/gui/pgrace_commuter_compass/
    ├── town_plugin.res.lua           # registers the card in the town window
    ├── station_plugin.res.lua        # registers the Waiting passengers card in the station window
    ├── pgrace_commuter_compass.script.tl  # UI: sections, tables, the map arrow and its distance label
    ├── arrow_label.css.lua           # lets the distance label's layer fill the screen
    ├── commuters.tl                  # reads game state: towns, positions, commuter counts
    ├── waiting.tl                    # reads game state: people waiting at a station and where they're going
    └── rank.tl                       # pure: sections, sorting, formatting (unit-tested)
tools/                                # type check, tests, install, release checks
tests/                                # unit tests for rank.tl
```

## Dev loop

```bash
just check      # type-check against the game's API definitions
just test       # unit tests
just verify     # check + test + release-check
just install    # symlink into TF3's staging area (just install-copy to copy)
```

Restart TF3 after code changes. The log is
`~/.local/share/Steam/userdata/*/3493540/local/crash_dump/stdout.txt`; our lines start with `[commuter_compass]`.

## In-game checklist

- [ ] A town window shows the **Commuters** card after the charts, with every section collapsed.
- [ ] Column headers sort the table; clicking again reverses the order. The window then scrolls to that section's
  header instead of jumping mid-list.
- [ ] The work and shop counts and line usage match the base Destinations table (Supplies tab).
- [ ] Town B in A's Outbound lists A in its Inbound, with the same counts.
- [ ] Nearby lists the 3 nearest towns with no commuters, with only Town and Distance columns.
- [ ] Locate moves the camera, and the name opens that town's window.
- [ ] The arrow is animated when line usage is above 0, and faint at 0% and on Nearby rows.
- [ ] Outbound arrows point away from the town, and Inbound arrows point towards it.
- [ ] Switching from one arrow to another (across sections too) moves the arrow on the first click.
- [ ] Toggling an arrow off, or closing the window, restores the town's normal overlay.
- [ ] Folding a section while an arrow shows keeps the arrow, without a camera jump.
- [ ] The arrow shows its distance at the top of its arc. The label follows the arc through pan, tilt and zoom,
  survives popups such as a town's celebration, changes with the arrow, and goes away when the arrow does.

Station card:

- [ ] A passenger station shows the **Waiting passengers** card. A cargo-only station doesn't.
- [ ] The card opens collapsed, showing only the totals, with Terminals right below; clicking the totals expands it.
- [ ] Collapsing the card hides any arrow it showed.
- [ ] The total roughly matches the base window's waiting counts (it lags by up to 2 seconds).
- [ ] A destination with several lines has a row per line, and each line name opens its own line.
- [ ] A shortened line name shows its full name as a tooltip.
- [ ] The numbers update by themselves. Rows keep their place, and the window doesn't move, even with an arrow on.
- [ ] Rows that empty out disappear, and new destinations appear.
- [ ] Clicking a header re-sorts the table and scrolls the window back to the card's totals line.
- [ ] Turning on the arrow in one of a destination's rows lights only that row's toggle.
- [ ] Arrows go from the station to the destination, and stay clear of the window.

Translations (switch the game's language):

- [ ] German: both cards, their headers, columns, hints and tooltips are translated; distances read "2,2 km",
  counts "1.240", percentages "45 %".
- [ ] Polish or Russian: counts take the right form (Russian "1 город", "2 города", "5 городов").
- [ ] Japanese, Korean or Chinese: the text renders (no boxes) and counts read naturally ("5町").

## Translations

Text shown in the game is wrapped in `_("...")`; the English text is the key. Translations live in
`mod/pgrace_commuter_compass/strings.json`, one block per language, for all 12 languages TF3 ships besides English
(de, es, fr, it, ja, ko, nl, pl, pt_BR, ru, zh_CN, zh_TW). Terms follow the base game's own translations
(`base/strings/<lang>/LC_MESSAGES/base.mo`).

**Counts** ("5 towns") have one key per plural form: `"{count} towns|one"`, `"|few"`, `"|many"`, `"|other"`. The
script picks the form with `rank.pluralCategory` (CLDR rules for the player's language, read from
`app.getUserProfile():getLanguage().code`). Each language translates only the forms it uses:

| Languages | Forms |
| --- | --- |
| en, de, es, it, nl, fr, pt_BR | one, other (French and Portuguese count 0 as one) |
| pl, ru | one, few, many |
| ja, ko, zh_CN, zh_TW | other |

English needs entries only for these plural keys; its other text is its own key.

`just release-check` fails if a language lacks a key or form it needs, or a translation drops a `{placeholder}`, and
warns about entries no longer needed. Distances and counts use the game's formatters (`api.util.formatLength`,
`api.util.lang.formatInt`), and percentages are a key (`"{percent}%"`), so all follow the player's language and units.
The Mod Hub name, summary and description are translated under `localization` in `_metadata/modinfo.json` (summaries
are checked against the 100-character limit); `description.html` stays English (mod.io shows only English for now).

To add a language: copy a block in `strings.json`, change the code, translate the values, add its plural forms to
`PLURAL_FORMS` in `tools/release_check.py` and to `rank.pluralCategory`, and run `just verify`.

## Releasing

1. Screenshots go in `mod/pgrace_commuter_compass/_metadata/`. `0.png` is the cover, and `1.png`, … are the gallery
   (1920x1080, at most 8 MB).
2. For an update: `just bump` and commit.
3. `just release` (revision check + verify).
4. Upload from **Mod Hub > My Mods** in TF3.
5. Commit what the upload changed (the first one creates `_metadata/mod.io_fileid.txt`), then `just mark-uploaded`
   and push `main`.

## Known limitations

- Town card: towns only. Industries and the HQ as work destinations (shown in the base table) are ignored.
- Station card: passengers only, not cargo. Between header clicks the order can be out of date (a row showing 40
  below one showing 12); click a header to re-sort. The Unknown rows sort with the others.
- The base station window itself is CPU-heavy at a busy hub (one game thread roughly doubles); the Waiting card adds
  little.
- No road or rail distance, and no travel times. The engine doesn't expose them to mods.
- Numbers in the table are left-aligned: the base game's right-aligned style only applies inside the Statistics
  window.
- If you pin the window while an arrow is showing and then open another window, our arrow keeps the map until you
  toggle it off or close the pinned window. This is the same as in Cargo Compass.
