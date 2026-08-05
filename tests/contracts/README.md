# Service API contracts

These files describe only the HTTP API calls made by MediaStack. Each service
file has exactly these top-level keys:

```yaml
service: sonarr
base_path: /api/v3
auth: {type: header, name: X-Api-Key}
openapi: https://upstream.example/openapi.json
endpoints:
  - id: quality-profile-list
    method: GET
    path: /qualityprofile
    sends: []
    reads: [id, name, items[].quality.id]
    callers: [scripts/lib/arr/quality.sh]
```

`openapi` is optional. It is present when an upstream specification is
available upstream; its absence means the service is live-replay-only.
`base_path` is the API prefix omitted from endpoint `path` values. `auth`
describes the service's normal request authentication shape. The inventory is
per service, and helpers under `scripts/lib/` are attributed to the service
whose API they call.

`auth.type` is one of `header`, `bearer`, `cookie`, `query`, or `none` (the
default when the block is absent) — `tests/contracts/replay.py`'s live mode
reads this generically, never with a per-service branch. `header` sets header
`auth.name` to the caller's credential verbatim, unless `auth.format` is also
given: a literal header-value template with the substring `{key}` replaced by
the credential, for a service whose real header value is structured (e.g.
Jellyfin's `MediaBrowser Client="...", Token="{key}"` scheme — see
`jellyfin.yml`). `bearer` sends `auth.name: Bearer <credential>`. `cookie`
sends a `Cookie: <auth.name>=<credential>` header. `query` appends
`<auth.name>=<credential>` to the request URL. A service whose live session
needs a *second*, supplementary cookie alongside its primary credential (e.g.
Jackett: an `apikey` query param plus a separate UI session cookie the API
alone doesn't carry) takes that second cookie via replay.py's `--cookie
NAME:RAW_COOKIE_HEADER` flag rather than a new auth type.

Endpoint `id` values are kebab-case and unique within a service. `method` is
the HTTP method and `path` is the route after `base_path`; query strings are
not part of the path. A path may contain `{id}` for one caller-substituted
single path segment. No other path construction is part of this format.

`sends` lists the JSON or form fields MediaStack sets. `reads` lists the
response fields it consumes. Both use dotted object paths. `[]` means an item
inside an array, so `items[].quality.id` means the `quality.id` field of every
element in `items`. These are field paths, not JSONPath: there are no filters,
wildcards, indexes, or other addressing syntax.

`callers` lists repository-relative script files that make the call. The
inventory is deliberately only-what-we-call: do not copy a service's full
published API into these files. `tests/contracts/check.py` enforces that every
literal endpoint call has an entry, every entry has a caller, and each caller
list matches the tree.

Its two failure kinds are opposite directions of that check. `missing contract`
means a call in the tree has no entry covering it — add the endpoint and its
caller to the service's file here, or fix the call if the route it names is
malformed. `dead contract entry` means the call an entry covered is gone —
delete the entry. Neither is fixed by loosening the check.
