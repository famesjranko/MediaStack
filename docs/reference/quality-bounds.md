# Quality Bounds Reference

MediaStack composes a quality profile from two **orthogonal** axes — a **resolution** (the desired ceiling) × a **size** (the file-size envelope) — picked in the setup wizard and combined at apply time. The profile name is `"{resolution} {size}"`, e.g. `1080p Balanced`.

Bounds are in **MB per minute** of runtime (Sonarr per episode, Radarr per movie). Sonarr and Radarr ship with very loose defaults — a single grab can land a 25 GB bloat release at one extreme or a 400 MB cam rip at the other. These bounds tighten both ends. Preferred sits in the middle of what real sources produce; max is a sane ceiling — **not** the TRaSH max-quality values, which target much larger files ([why](#why-these-bounds-and-not-trash-defaults)).

Source of truth: [`scripts/setup/presets.yml`](../../scripts/setup/presets.yml) (`quality_ids` / `resolutions` / `sizes`). The wizard writes the chosen cell into `config.yml`; `configure.sh` then applies it to Sonarr/Radarr via API. The `config.yml` output shape is unchanged from the old single-preset model, so the renderer is untouched.

## The two axes

**Resolution = the desired ceiling.** Pick **720p** or **1080p**. A resolution enables **every quality tier from the SD floor up to its ceiling**, all source types (SDTV/DVD/480p, then HDTV/WEBRip/WEBDL/Bluray at each resolution up to the ceiling), and sets the **cutoff** to its WEB group (720p → 1001, 1080p → 1002). Upgrades climb toward the ceiling and stop there.

- **Best-available is automatic.** The renderer inherits each app's canonical worst→best quality ordering, so a 1080p release always outranks a 720p, which outranks SD. SD/720p are only ever **fallbacks** that get grabbed when nothing better exists yet, then **upgraded away** (the cutoff sits above them; `upgrade_allowed` is on). This is why enabling the SD floor doesn't make profiles "behave SD" — best-available always wins the initial grab, and the cutoff is above SD.
- **SD floor.** Enabling SDTV/DVD/480p means an older or obscure title that only exists in SD is still grabbed (then upgraded if a better release appears later) instead of never being grabbed at all.

**Size = the file-size envelope only** — `compact` / `balanced` / `large`: per-tier min/preferred/max bounds + custom-format scores. It is **source-agnostic**: a size does not filter WEB vs HDTV/Bluray; every size includes the full tier ladder. `balanced` is the authored reference; `compact ≈ 0.7×` and `large ≈ 1.2×` its preferred/max (mins are the source floor, size-independent).

## Cells at a glance

| | Compact | Balanced | Large |
|---|---|---|---|
| **720p** (cutoff WEB 720p) | `720p Compact` ~1.5-3 GB/movie | `720p Balanced` ~2-4 GB/movie | `720p Large` ~3-5 GB/movie |
| **1080p** (cutoff WEB 1080p) | `1080p Compact` ~2-4 GB/movie | `1080p Balanced` (default) ~4-8 GB/movie | `1080p Large` ~6-15 GB/movie |

Remux (Remux-720p/1080p, IDs 30+) is intentionally excluded from every cell — it's a videophile feature (25-40 GB single grabs) that doesn't fit the home-server audience. Users who want it can add it to `config.yml` post-wizard. Adding a **2160p / 4K** resolution is a pure data addition to `presets.yml` (a future epic) — see [Adding a resolution](#adding-a-resolution).

## Size bounds — Compact (≈0.7× balanced)

| Tier | Sonarr min/pref/max | Radarr min/pref/max |
|---|---:|---:|
| SDTV | 1.0 / 6.0 / 18.0 | 1.0 / 6.0 / 18.0 |
| DVD | 2.0 / 8.0 / 21.0 | 2.0 / 8.0 / 21.0 |
| WEBDL-480p | 1.0 / 6.0 / 18.0 | 1.0 / 6.0 / 18.0 |
| WEBRip-480p | 1.0 / 6.0 / 18.0 | 1.0 / 6.0 / 18.0 |
| Bluray-480p | 2.0 / 10.0 / 25.0 | 2.0 / 10.0 / 25.0 |
| HDTV-720p | 12.0 / 21.0 / 35.0 | 2.0 / 17.5 / 35.0 |
| WEBDL-720p | 8.0 / 20.0 / 35.0 | 2.0 / 22.0 / 37.0 |
| WEBRip-720p | 8.0 / 20.0 / 35.0 | 2.0 / 22.0 / 37.0 |
| Bluray-720p | 18.0 / 28.0 / 42.0 | 4.0 / 21.0 / 38.5 |
| HDTV-1080p | 18.0 / 31.5 / 52.5 | 4.0 / 35.0 / 56.0 |
| WEBDL-1080p | 12.0 / 31.5 / 52.5 | 4.0 / 35.0 / 56.0 |
| WEBRip-1080p | 12.0 / 31.5 / 52.5 | 4.0 / 35.0 / 56.0 |
| Bluray-1080p | 30.0 / 42.0 / 63.0 | 10.0 / 45.5 / 63.0 |

## Size bounds — Balanced (1.0×, the authored reference)

| Tier | Sonarr min/pref/max | Radarr min/pref/max |
|---|---:|---:|
| SDTV | 1.0 / 8.0 / 25.0 | 1.0 / 8.0 / 25.0 |
| DVD | 2.0 / 12.0 / 30.0 | 2.0 / 12.0 / 30.0 |
| WEBDL-480p | 1.0 / 8.0 / 25.0 | 1.0 / 8.0 / 25.0 |
| WEBRip-480p | 1.0 / 8.0 / 25.0 | 1.0 / 8.0 / 25.0 |
| Bluray-480p | 2.0 / 14.0 / 35.0 | 2.0 / 14.0 / 35.0 |
| HDTV-720p | 12.0 / 30.0 / 50.0 | 2.0 / 25.0 / 50.0 |
| WEBDL-720p | 10.0 / 30.0 / 50.0 | 2.0 / 25.0 / 50.0 |
| WEBRip-720p | 10.0 / 30.0 / 50.0 | 2.0 / 25.0 / 50.0 |
| Bluray-720p | 18.0 / 40.0 / 60.0 | 4.0 / 30.0 / 55.0 |
| HDTV-1080p | 18.0 / 45.0 / 75.0 | 4.0 / 50.0 / 80.0 |
| WEBDL-1080p | 12.0 / 45.0 / 75.0 | 4.0 / 50.0 / 80.0 |
| WEBRip-1080p | 12.0 / 45.0 / 75.0 | 4.0 / 50.0 / 80.0 |
| Bluray-1080p | 30.0 / 60.0 / 90.0 | 10.0 / 65.0 / 90.0 |

## Size bounds — Large (≈1.2× balanced)

| Tier | Sonarr min/pref/max | Radarr min/pref/max |
|---|---:|---:|
| SDTV | 1.0 / 10.0 / 30.0 | 1.0 / 10.0 / 30.0 |
| DVD | 2.0 / 14.0 / 36.0 | 2.0 / 14.0 / 36.0 |
| WEBDL-480p | 1.0 / 10.0 / 30.0 | 1.0 / 10.0 / 30.0 |
| WEBRip-480p | 1.0 / 10.0 / 30.0 | 1.0 / 10.0 / 30.0 |
| Bluray-480p | 2.0 / 17.0 / 42.0 | 2.0 / 17.0 / 42.0 |
| HDTV-720p | 12.0 / 30.0 / 55.0 | 2.0 / 30.0 / 60.0 |
| WEBDL-720p | 10.0 / 30.0 / 55.0 | 2.0 / 30.0 / 60.0 |
| WEBRip-720p | 10.0 / 30.0 / 55.0 | 2.0 / 30.0 / 60.0 |
| Bluray-720p | 18.0 / 40.0 / 60.0 | 4.0 / 40.0 / 65.0 |
| HDTV-1080p | 18.0 / 55.0 / 90.0 | 4.5 / 55.0 / 90.0 |
| WEBDL-1080p | 12.0 / 55.0 / 85.0 | 4.3 / 55.0 / 85.0 |
| WEBRip-1080p | 12.0 / 55.0 / 85.0 | 4.3 / 55.0 / 85.0 |
| Bluray-1080p | 30.0 / 80.0 / 125.0 | 10.0 / 85.0 / 125.0 |

A cell uses the rows for its resolution's tiers only — `720p Balanced` applies the SD-floor + 720p rows of the Balanced table; `1080p Balanced` applies the SD → 1080p rows. The 1080p rows of a 720p cell are simply not enabled.

## Custom format scores

Scores **steer** release selection within a quality tier — higher = preferred, negative = penalised. They do **not** gate file size (the bounds above do), and by default **nothing is hard-blocked**. Scores are the **same across all three sizes** — release quality is size-independent; the size axis is the bounds envelope only.

| Format | Score | Effect |
|---|---:|---|
| Repack/Proper | 5 | prefer the repacked / proper release |
| x264 | 0 | neutral |
| x265 (HD) | 0 | neutral — the server transcodes, so HEVC direct-play is a non-issue, and x265 is smaller (helps the size goal) |
| BR-DISK | 0 | not blocked here — a full disc image is rejected by the size envelope, and is grabbable if you raise the bounds to want it |
| LQ | -100 | soft penalty on low-quality re-encode groups (YIFY/YTS/…): dispreferred, but grabbed as a last resort when nothing better exists |
| No-RlsGroup | -10 | slight nudge toward releases with a recognised group tag |
| Obfuscated | -10 | slight nudge against scrambled / anonymous release names |

The profile's reject floor (`minFormatScore`, `-1000` in `render/quality_profile.py`) sits below the worst default penalty stack (~-120) so **nothing is score-blocked by default**, and above `-10000` so a format you *deliberately* set to `-10000` still hard-blocks. **Do not raise `minFormatScore` to `0`** — that turns every negative score into a hard reject. To hard-block a format (e.g. a full BluRay disc), set its score to `-10000` in `config.yml`.

HDR / Dolby Vision custom formats are deliberately not added — the home-server audience typically doesn't have HDR-capable playback gear, and HDR releases run 25-40% larger at the same nominal quality, working against the size-control goal. (A 4K column would revisit this.)

Format definitions (the regex conditions that match each format) are developer-managed in [`scripts/lib/arr/custom_formats.yml`](../../scripts/lib/arr/custom_formats.yml) — the scores above are what users tune.

## Why these bounds and not TRaSH defaults

TRaSH Guides values target maximum-quality grabs. Their typical 1080p WEB-DL preferred is ~137 MB/min — at a 110-min movie that's a 15 GB file — and TRaSH leaves **preferred/max effectively unlimited** (≈1000 for Sonarr, ≈2000 for Radarr, both meaning "no cap") for **every** tier, SD floor included. Real Netflix/Amazon/Disney 1080p WEB-DL releases are 4-7 GB; setting preferred at the TRaSH default biases the system to over-bloated releases. MediaStack's bounds put the preferred peak in the middle of what real sources actually produce, with max as a sane ceiling. TRaSH **is** authoritative for the **mins** (the source floor, e.g. ~5 MB/min for SD); MediaStack's contribution is the per-band preferred/max envelope. (Custom-format *scores* were also once TRaSH-derived but were retuned to a neutral, non-blocking baseline — see [Custom format scores](#custom-format-scores).)

Reference table for sanity-checking:

| Source | 2-hour movie | 45-min episode |
|---|---|---|
| SD (SDTV/DVD/480p) | 0.5-2 GB | 0.1-0.5 GB |
| 720p WEB-DL | 1.5-3 GB | 0.4-0.9 GB |
| 1080p WEB-DL (Netflix/Amazon/Disney) | 4-7 GB | 1.0-2.5 GB |
| 1080p Bluray x264 rip | 8-12 GB | 2.5-4 GB |
| 1080p Bluray Remux (excluded) | 25-40 GB | 8-15 GB |

## Changing the values

**Switch cells, day-2 (recommended after install)** — from the launcher:

```bash
./mediastack   →  Features & settings  →  Change quality profile (resolution & size)
```

Re-pick a resolution, then a size. The launcher rewrites only the quality sections of `config.yml` (your indexers, subtitles and bandwidth are untouched) and re-pushes to Sonarr/Radarr. Because the profile name is `"{resolution} {size}"`, changing a cell renames the profile (`1080p Balanced` → `1080p Large`); the launcher renames the existing profile **in place** (same profile id), so your existing series/movies follow the change and **no orphaned profile is left behind**. You are warned first that raising the ceiling or size makes Sonarr/Radarr re-search and upgrade existing media (extra downloads and disk use).

> Downgrading the resolution (e.g. 1080p → 720p) disables the higher tiers in the profile but leaves their **global** `quality_definitions` bounds in place — they are shared across all profiles and simply go unused by the narrower profile. This is expected, not a leak.

**Switch cells during setup** — re-run the wizard:

```bash
./scripts/setup/wizard.sh
```

Pick a resolution, then a size; the wizard rewrites `config.yml`. Then re-run `./configure.sh` to push the new bounds and scores to Sonarr/Radarr.

**Hand-tune within a cell** — edit `config.yml` directly:

- `quality_definitions.sonarr.<Quality>: { min, preferred, max }`
- `quality_definitions.radarr.<Quality>: { min, preferred, max }`
- `custom_formats.<Format>: <score>`

Then re-run `./configure.sh`. The renderer (`scripts/lib/arr/render/quality_definitions.py`) reads live state via `GET /api/v3/qualitydefinition` and only `PUT`s tiers that differ from `config.yml`. If you've been editing values in the Sonarr/Radarr UI directly, expect a `log_warn` rather than a silent overwrite — re-runs surface drift but never auto-reconcile.

## Adding a resolution

Adding a 2160p / 4K column is a **pure data change** to `presets.yml`: a new `resolutions` block (tier names + `cutoff_group: 1003`), its numeric IDs in `quality_ids`, and (optionally) 2160p `bounds` rows in each size table — with **no** edit to `wizard_apply.py`, `stage1.sh`, or `render/*.py`. The wizard menus and composition pick it up automatically. (`tests/unit/wizard-composition.sh` proves this.) The policy reversals 4K forces — HDR/Dolby-Vision and Remux re-enablement, x265 scoring inverting to positive — are a deliberate follow-up; the structure here only has to leave them expressible as data.

## Upstream references

- TRaSH Guides — Sonarr quality settings file size: https://trash-guides.info/Sonarr/Sonarr-Quality-Settings-File-Size/
- TRaSH Guides — Radarr quality settings file size: https://trash-guides.info/Radarr/Radarr-Quality-Settings-File-Size/
- Related: [`docs/setup/configuration-schema.md`](../setup/configuration-schema.md) — `quality_profile`, `quality_definitions`, `custom_formats` schema reference
