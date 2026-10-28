# Service API contracts

These files describe only the HTTP API calls made by MediaStack. Each service
file has the top-level keys `service`, `base_path`, `auth` and `endpoints`,
plus an optional `openapi`:

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

`auth.type` is one of `header`, `bearer`, `cookie`, `query`, `basic`, or `none`
(the default when the block is absent; `basic` is sent as no auth) — `tests/contracts/replay.py`'s live mode
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
not part of the path. A path may contain two placeholders, each for exactly one
caller-substituted segment:

- `{id}` is a generated identifier: digits, a UUID, or 16 or more hex digits.
  It does not match a word, so `/settings/{id}` does not cover an unlisted
  sibling such as `/settings/about`.
- `{key}` is any one segment, for an API keyed by a name or an opaque key, such
  as Jackett indexer names and PocketBase record ids.

When the caller names the segment literally, give each name its own entry, as
`seerr.yml` does for `/settings/sonarr` and `/settings/radarr`. No other path
construction is part of this format.

`sends` lists the JSON or form fields MediaStack sets. `reads` lists the
response fields it consumes. Both use dotted object paths. `[]` means an item
inside an array, so `items[].quality.id` means the `quality.id` field of the
elements in `items`. These are field paths, not JSONPath: there are no filters,
wildcards, indexes, or other addressing syntax. When the response is a list,
the paths apply to its elements; an object whose values are all objects (a
collection keyed by name) is read the same way.

A recorded response shows a read only when the path is found in it, every
array along the path, including a top-level list, is non-empty, and the value
is not null, an empty string, or an empty list or object. The JSON helpers in
`scripts/lib/json.sh` turn null into their default, so such a value proves no
read. An empty list therefore proves no read. Reads may be shown by different calls to the same
entry, so a list that is empty before a create and filled after it proves its
reads. `tests/contracts/inventory.py` owns this rule for every consumer.

Three optional endpoint keys serve the image acceptance gate:

- `expect` lists the HTTP statuses that count as a successful call, as
  integers from 100 to 599. Without it, any 2xx counts.
- `base_path` overrides the file's `base_path` for one entry, for example a
  readiness probe at the service root.
- `unexercised` names why the image jobs cannot reach the entry. It is one of
  `gpu`, `remote-profile`, `launcher-menu`, `nas`, or `held-profile`.
  `held-profile` is valid only for a service in `HELD` in
  `tests/preflight/model.py`. Such an entry does not block acceptance; if a job
  does exercise it, the gate reports the exemption as stale.

```yaml
  - {id: readiness, method: GET, base_path: /, path: /, expect: [200, 301, 302, 303, 307, 308], sends: [], reads: [], callers: [scripts/configure.sh]}
```

Readiness probes are calls too. `check.py` reads the polled URL from
`wait_for_service`, `wait_for_healthy` and `post_restart_wait`. The URL should
be `"$(service_local_url NAME)"`, optionally with a path suffix, or a variable
assigned from it in the same function or at file level. A URL whose route the
check cannot resolve fails as an `unrecognised probe`. The same
`service_local_url` form attributes any other call to service NAME. A bare
service root is reachable only through such a named service, because a root
path alone names no service.

`callers` lists repository-relative script files that make the call. The
inventory is deliberately only-what-we-call: do not copy a service's full
published API into these files. `tests/contracts/check.py` enforces that every
literal endpoint call has an entry, every entry has a caller, and each caller
list matches the tree.

Its two main failure kinds are opposite directions of that check. `missing
contract` means a call in the tree has no entry covering it — add the endpoint
and its caller to the service's file here, or fix the call if the route it
names is malformed. `dead contract entry` means the call an entry covered is
gone — delete the entry. Neither is fixed by loosening the check. A `caller
mismatch` names an entry whose `callers` differ from the tree, and a `schema:`
error names an entry that breaks this format.
