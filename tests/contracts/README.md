# Service API contracts

These files describe only the HTTP API calls and the `docker exec` calls made
by MediaStack. Each service file has the top-level keys `service`, `base_path`,
`auth` and `endpoints`, plus an optional `openapi` and an optional `exec` (see
[Exec entries](#exec-entries)):

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
available; `tests/contracts/replay.py spec` checks each endpoint's method and
path against it, and skips a service without one. `base_path` is the API
prefix omitted from endpoint `path` values. `auth` describes the service's
normal request authentication shape. The inventory is per service, and helpers
under `scripts/lib/` are attributed to the service whose API they call.

`auth.type` is one of `header`, `bearer`, `cookie`, `query`, `basic`, `form`,
or `none` (the default when the block is absent). `tests/mock/serve.py`
shape-checks it generically, never with a per-service branch. `header` names
the header that carries the credential; `auth.format` documents a structured
header value, with `{key}` for the credential (e.g. Jellyfin's
`MediaBrowser Client="...", Token="{key}"` scheme — see `jellyfin.yml`).
`bearer` is `auth.name: Bearer <credential>`. `cookie` is a
`Cookie: <auth.name>=<credential>` header. `query` is
`<auth.name>=<credential>` in the request URL.

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

## Exec entries

Some touchpoints are binaries inside a service image, run with `docker exec`:
`fail2ban-client`, `nginx -t`, `/beszel superuser upsert`. The optional
top-level `exec` key lists them. A file with no HTTP API, such as
`fail2ban.yml`, has `endpoints: []` and may omit `base_path` and `auth`.

```yaml
exec:
  - {id: client-reload, command: [fail2ban-client, reload], callers: [scripts/configure.sh]}
  - {id: regex-count, command: [sh, -c], match: fail2ban-regex, callers: [scripts/lib/health.sh]}
  - {id: certbot-lock, command: [sh, -c], match: /tmp/letsencrypt-lib/.certbot.lock, expect_exit: [0, 10], callers: [scripts/services/npm/certs.sh]}
```

- The container is the file's `service`; each MediaStack container is named
  after its service.
- `command` is a prefix of the words after the container name. Each word is a
  literal: no variable, quote or space. A call matches the entry with the
  longest prefix, and then an entry with `match` over one without.
- `match` is for an `sh -c` script: a substring of the word after the prefix.
  It is broad: a `match` entry credits any `sh -c` script of its service that
  contains the substring. A script that contains the `match` of two entries
  with the same command matches neither, and so counts as unlisted. Two
  entries with the same command must not overlap: both without `match`, or
  with one `match` inside the other, is a `schema:` error.
- `expect_exit` lists the accepted exit statuses, from 0 to 255. Without it,
  only 0 counts.
- `unexercised` uses the same closed set of reasons as an endpoint.
- Ids are unique across `endpoints` and `exec` in one file.

`check.py` reads each `docker exec [flags] CONTAINER COMMAND...` in
`scripts/`. The flags `-u`, `-e`, `-w` and their long forms take a value; an
unknown flag makes the call unreadable. The container must be a literal service
name, or a variable that takes only that one literal name in the same function,
or at file level: from its assignments and `for` lists. A variable that is also
set by `read`, `printf -v`, `+=` or a nameref cannot be read. A command array,
as in `docker "${cmd[@]}"` or `sudo docker "${cmd[@]}"`, is read from its one
literal assignment. A call that the check cannot read fails as an
`unparseable exec`, and so does `docker container exec` or
`docker compose exec`. The only exclusion is the dry-run sandbox container,
`$cname` in `scripts/lib/dry-run.sh`, which is not a service.

Any other line that names docker and then the word `exec` fails as a
`possible exec call not parsed`: for example `docker -H host exec`,
`$DOCKER exec`, or `sh -c "docker exec ..."`. Write the call in the form above.
A comment line is passed over. A line that only prints a docker exec command
goes in `MESSAGES` in `exec_scan.py`, after you make sure that it runs nothing.
`missing contract` and `dead contract entry` mean the same for exec entries as
for endpoints.

In the image jobs, `tests/lib/contract-trace-docker.sh` records each product
`docker exec`, also one after docker's global flags such as `-H` or
`--context`: the container, the words after it and the exit status. The
verdict needs each exec entry without `unexercised` to exit with an accepted
status on the candidate, and no unlisted exec into the candidate on any image.
The evidence holds no argument values: `contracts.json` keeps exit counts per
entry, and an unlisted exec keeps only its first word and the inventory words
after it.
