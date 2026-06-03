# Quality Bounds Reference

Per-quality file-size bounds for each of MediaStack's three quality presets, in MB per minute of runtime (Sonarr per episode, Radarr per movie). Sonarr and Radarr ship with very loose defaults — a single grab can land a 25 GB bloat release at one extreme or a 400 MB cam rip at the other. These bounds tighten both ends. Values are calibrated to deliver the size each preset advertises, based on real-world 1080p WEB-DL (4-7 GB/movie), 1080p Bluray rip (8-12 GB/movie), and 720p WEB-DL (1.5-3 GB/movie) ranges — not the TRaSH max-quality values, which target much larger files.

Source of truth: [`scripts/setup/presets.yml`](../../scripts/setup/presets.yml). The setup wizard (`scripts/setup/wizard.sh`) writes the chosen preset into `config.yml`, and `configure.sh` then applies it to Sonarr/Radarr via API.

## Presets at a glance

| Preset | Profile name | Cutoff | Qualities enabled | Approx size |
|---|---|---|---|---|
| **Compact** | `WEB-720p/1080p` | WEB 720p | WEB 720p only (no 1080p, no HDTV/Bluray) | ~2-4 GB/movie |
| **Balanced** | `HD-720p/1080p` | WEB 1080p | All 720p+1080p (HDTV/WEB/Bluray, no Remux) | ~4-8 GB/movie |
| **Quality** | `HQ-1080p` | WEB 1080p | 1080p + 720p fallback (no Remux) | ~6-15 GB/movie |

Tiers not listed (480p, 2160p, Remux-720p, Remux-1080p) keep upstream Sonarr/Radarr defaults; **none are enabled in any profile**. Remux is intentionally excluded across all presets — it's a videophile feature (single grabs of 25-40 GB) that doesn't fit the home-server audience.

## Sonarr file-size bounds

Units: **MB per minute, per episode**.

### Compact

| Quality | Min | Preferred | Max |
|---|---:|---:|---:|
| WEBDL-720p | 8.0 | 20.0 | 35.0 |
| WEBRip-720p | 8.0 | 20.0 | 35.0 |

### Balanced

| Quality | Min | Preferred | Max |
|---|---:|---:|---:|
| HDTV-720p | 12.0 | 30.0 | 50.0 |
| WEBDL-720p | 10.0 | 30.0 | 50.0 |
| WEBRip-720p | 10.0 | 30.0 | 50.0 |
| Bluray-720p | 18.0 | 40.0 | 60.0 |
| HDTV-1080p | 18.0 | 45.0 | 75.0 |
| WEBDL-1080p | 12.0 | 45.0 | 75.0 |
| WEBRip-1080p | 12.0 | 45.0 | 75.0 |
| Bluray-1080p | 30.0 | 60.0 | 90.0 |

### Quality

| Quality | Min | Preferred | Max |
|---|---:|---:|---:|
| HDTV-720p | 12.0 | 30.0 | 55.0 |
| WEBDL-720p | 10.0 | 30.0 | 55.0 |
| WEBRip-720p | 10.0 | 30.0 | 55.0 |
| Bluray-720p | 18.0 | 40.0 | 60.0 |
| HDTV-1080p | 18.0 | 55.0 | 90.0 |
| WEBDL-1080p | 12.0 | 55.0 | 85.0 |
| WEBRip-1080p | 12.0 | 55.0 | 85.0 |
| Bluray-1080p | 30.0 | 80.0 | 125.0 |

## Radarr file-size bounds

Units: **MB per minute, per movie**.

### Compact

| Quality | Min | Preferred | Max |
|---|---:|---:|---:|
| WEBDL-720p | 2.0 | 22.0 | 37.0 |
| WEBRip-720p | 2.0 | 22.0 | 37.0 |

### Balanced

| Quality | Min | Preferred | Max |
|---|---:|---:|---:|
| HDTV-720p | 2.0 | 25.0 | 50.0 |
| WEBDL-720p | 2.0 | 25.0 | 50.0 |
| WEBRip-720p | 2.0 | 25.0 | 50.0 |
| Bluray-720p | 4.0 | 30.0 | 55.0 |
| HDTV-1080p | 4.0 | 50.0 | 80.0 |
| WEBDL-1080p | 4.0 | 50.0 | 80.0 |
| WEBRip-1080p | 4.0 | 50.0 | 80.0 |
| Bluray-1080p | 10.0 | 65.0 | 90.0 |

### Quality

| Quality | Min | Preferred | Max |
|---|---:|---:|---:|
| HDTV-720p | 2.0 | 30.0 | 60.0 |
| WEBDL-720p | 2.0 | 30.0 | 60.0 |
| WEBRip-720p | 2.0 | 30.0 | 60.0 |
| Bluray-720p | 4.0 | 40.0 | 65.0 |
| HDTV-1080p | 4.5 | 55.0 | 90.0 |
| WEBDL-1080p | 4.3 | 55.0 | 85.0 |
| WEBRip-1080p | 4.3 | 55.0 | 85.0 |
| Bluray-1080p | 10.0 | 85.0 | 125.0 |

## Custom format scores

Higher = preferred. `-10000` is a hard block — releases matching that format never get grabbed. `BR-DISK` and `LQ` are hard-blocked across all presets.

| Format | Compact | Balanced | Quality |
|---|---:|---:|---:|
| Repack/Proper | 5 | 5 | 5 |
| x264 | 0 | 10 | 10 |
| x265 (HD) | 0 | -25 | -50 |
| BR-DISK | -10000 | -10000 | -10000 |
| LQ | -10000 | -10000 | -10000 |
| No-RlsGroup | -10 | -25 | -25 |
| Obfuscated | -10 | -25 | -25 |

Compact is more permissive on missing-group / obfuscated releases (since smaller WEB releases more often lack standard group tags). Balanced and Quality both prefer x264 and penalize x265 — x265 is harder for some clients to direct-play. Quality penalizes x265 more aggressively because it stays at 1080p where x264 quality at higher bitrates is mature.

HDR / Dolby Vision custom formats are deliberately not added — the home-server audience targeted by this stack typically doesn't have HDR-capable playback gear, and HDR releases run 25-40% larger at the same nominal quality, working against the size-control goal.

Format definitions (the regex conditions that match each format) are developer-managed in [`scripts/lib/arr/custom_formats.yml`](../../scripts/lib/arr/custom_formats.yml) — the scores above are what users tune.

## Why these bounds and not TRaSH defaults

TRaSH Guides values target maximum-quality grabs. Their typical 1080p WEB-DL preferred is ~137 MB/min — at a 110-min movie that's a 15 GB file. Real Netflix/Amazon/Disney 1080p WEB-DL releases are 4-7 GB; setting preferred at the TRaSH default biases the system to over-bloated releases (or simply doesn't find anything close to "preferred" and falls back to the largest available). MediaStack's bounds put the preferred peak in the middle of what real 1080p sources actually produce, with max set as a sane ceiling.

Reference table for sanity-checking:

| Source | 2-hour movie | 45-min episode |
|---|---|---|
| 720p WEB-DL | 1.5-3 GB | 0.4-0.9 GB |
| 1080p WEB-DL (Netflix/Amazon/Disney) | 4-7 GB | 1.0-2.5 GB |
| 1080p Bluray x264 rip | 8-12 GB | 2.5-4 GB |
| 1080p Bluray Remux | 25-40 GB | 8-15 GB |

## Changing the values

**Switch presets** — re-run the wizard:

```bash
./scripts/setup/wizard.sh
```

Pick a different tier; the wizard rewrites `config.yml`. Then re-run `./configure.sh` to push the new bounds and scores to Sonarr/Radarr.

**Hand-tune within a preset** — edit `config.yml` directly:

- `quality_definitions.sonarr.<Quality>: { min, preferred, max }`
- `quality_definitions.radarr.<Quality>: { min, preferred, max }`
- `custom_formats.<Format>: <score>`

Then re-run `./configure.sh`. The renderer (`scripts/lib/arr/render/quality_definitions.py`) reads live state via `GET /api/v3/qualitydefinition` and only `PUT`s tiers that differ from `config.yml`. If you've been editing values in the Sonarr/Radarr UI directly, expect a `log_warn` rather than a silent overwrite — re-runs surface drift but never auto-reconcile.

## Upstream references

- TRaSH Guides — Sonarr quality settings file size: https://trash-guides.info/Sonarr/Sonarr-Quality-Settings-File-Size/
- TRaSH Guides — Radarr quality settings file size: https://trash-guides.info/Radarr/Radarr-Quality-Settings-File-Size/
- Related: [`docs/setup/configuration-schema.md`](../setup/configuration-schema.md) — `quality_profile`, `quality_definitions`, `custom_formats` schema reference
