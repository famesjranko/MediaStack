# tests/mock/ — contract-driven mock server

`serve.py` is one generic, stdlib-only mock HTTP server. It has zero
per-service branches; every per-service detail lives in `tests/contracts/`
and `tests/mock/fixtures/`. See `tests/contracts/README.md` for the contract
schema and `tests/README.md` "Contract mocks and drift replay" for how the
`contract-mock` scenario drives it.

## Behavior notes

- **Route matching.** Each contract endpoint's `base_path` + `path` becomes a
  regex, with `{id}` matching one path segment. The first matching
  `(method, path)` wins.
- **Auth is shape-checked, never simulated.** `header`/`bearer` check the
  named header is present (and, for `bearer`, prefixed `Bearer `); `basic`
  checks an `Authorization: Basic ...` header; `cookie` checks
  `<name>=` appears in the `Cookie` header; `query` checks the parameter is
  present on the request path; `form` checks the declared field(s) are
  present in a parsed JSON or form body. A shape failure returns `401` and is
  still journaled.
- **Fixture lookup.** `tests/mock/fixtures/<service>/<endpoint-id>.json`,
  where `<endpoint-id>` is the contract entry's `id`. Two shapes:
  - `{"status": 200, "body": {...}}` — a fixed response.
  - `{"responses": [{"status": ..., "body": ...}, ...]}` — an ordered list
    consumed one entry per call to that endpoint (extra calls repeat the
    last entry). This is the *only* retry/failure-injection mechanism; there
    is no other way to make an endpoint behave differently across calls.
- **Missing fixture = auto-response.** If no fixture file exists, the mock
  answers `200` with a body built from the endpoint's `reads` fields: each
  dotted path is set to a zero-ish placeholder (`0` for a scalar leaf, one
  empty-object array element for a `[]` segment). This is documented,
  minimal behavior — write a real fixture whenever a script's branching
  depends on a specific value (an empty list vs. a populated one, a specific
  field value like `authenticationMethod: forms`), since the auto-response
  is a dict shape and some list-returning endpoints need an actual JSON
  array.
- **Root path liveness.** `GET /` always returns `200 {}` and is not
  journaled — a single generic rule (not a per-service branch) so
  `wait_for_service`/`curl -sf` readiness probes succeed against the mock
  the same way they would against a booting real container.
- **Journal.** Every non-root request is appended as one JSON line to the
  `--journal` path: `{"service", "method", "path", "endpoint", "status",
  "sent"}`. `endpoint` is `null` for a route with no contract match (still
  `404`, still journaled).
- **Statelessness.** The mock never remembers what a previous request
  created — a `GET` list endpoint returns the same fixture body regardless
  of an earlier `POST` to the "create" endpoint. A flow that needs
  read-your-writes belongs in `tests/api-matrix/`, not here (see
  `tests/README.md` "Division of labor").

## Running standalone

```bash
python3 tests/mock/serve.py --service sonarr:8989 --service radarr:7878 \
    --journal /tmp/mock-journal.jsonl
```
