# ddns-updater can log provider credentials, and MediaStack only shortens how long

## Context

`ddns-updater` (`qmcgaw/ddns-updater`) builds each provider update as an HTTP
request. When the request fails at the network layer (DNS failure, refused
connection, timeout, provider outage), `client.Do` returns a Go `*url.Error`
whose text includes the request URL, and the updater logs it and stores it as
the record message shown on the web UI (port 8000). For Dynu that is
`ERROR doing http request: Get "https://api.dynu.com/nic/update?hostname=...&password=<password>&username=...": dial tcp ...`.
A live Dynu outage on a test host produced nine such lines in
`docker logs ddns-updater`. A local probe reproduced the line with
`LOG_LEVEL=error`, so the log level does not hide it.

Upstream (read at commit `7d6fd78`, the tip when `qmcgaw/ddns-updater:latest`
was pinned in `docs/operations/image-digests.lock`; the image carries no
version tag) has no setting that redacts credentials from log lines or record
messages. No upstream issue about this behaviour was found.

Who can read the line: anyone who can run `docker logs` (the `docker` group,
which is already root-equivalent on the host), a Portainer administrator, and
anyone the operator pastes logs to when asking for help.

### Per provider

Paths are under `internal/provider/providers/` in `qdm12/ddns-updater` at
`7d6fd78`. The wizard offers these six providers
(`scripts/lib/ddns-providers.sh`, `_DDNS_KEY`). The same set serves setup and
the day-2 DDNS action.

| Provider | Credential travels in | Upstream line | Leaks in logs | Scoped credential | Residual risk |
|---|---|---|---|---|---|
| Dynu | URL query `password=` | `dynu/provider.go:126`; wrapped error `:145` | Yes | IP Update Password, separate from the account password and limited to IP updates ([Dynu IP update protocol](https://www.dynu.com/DynamicDNS/IP-Update-Protocol)) | A leaked line lets someone change the IP of the Dynu records, not take the account |
| DuckDNS | URL query `token=` | `duckdns/provider.go:144`; raw error `:160` | Yes | None: the token is the account token ([DuckDNS spec](https://www.duckdns.org/spec.jsp)) | A leaked line exposes the whole DuckDNS account; rotate the token after an outage that logged it |
| dynv6 | URL query `token=` | `dynv6/provider.go:119`; raw error `:136` | Yes | HTTP token restricted to one zone ([dynv6 API](https://dynv6.github.io/api-spec/), [update API](https://dynv6.com/docs/apis)) | With a zone-limited token a leaked line exposes that zone only |
| deSEC | URL userinfo (`user:token@`) | `desec/provider.go:109`; raw error `:133` | No: Go `net/http` replaces the userinfo password with `***` in `url.Error` | Token policies limit a token by domain, subname and record type ([deSEC token scoping](https://desec.readthedocs.io/en/latest/auth/tokens.html)) | None from logs. Not verified by a live failure; it rests on the Go standard library |
| Cloudflare | `Authorization: Bearer` header | `cloudflare/provider.go:157` (set in `setHeaders` `:151-163`) | No: the URL holds only the zone ID | API token with Zone / DNS / Edit on one zone ([Cloudflare API tokens](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)) | None from logs |
| Porkbun | JSON request body (`apikey`, `secretapikey`) | `porkbun/api.go:35-39`, `:151` | No: the URL holds no secret | Per-key domain and permission limits ([Porkbun API guide](https://kb.porkbun.com/article/190-getting-started-with-the-porkbun-api)) | None from logs |

Only the three URL-query providers leak. The wizard and the day-2 DDNS action
show a hint before the credential prompt for each of them (`ddns_field_hint`,
`scripts/lib/ddns-providers.sh`, called from `scripts/setup/stage2/ddns.sh` and
`scripts/launcher/ddns.sh`).

## Decision

MediaStack keeps the upstream behaviour and shortens the exposure:

- The `ddns-updater` service uses a 1 MB x 2 file `json-file` rotation instead of
  the shared 10 MB x 3, so a failure that has ended leaves the log within days
  rather than months. This applies to every provider.
- For each URL-query provider the wizard and the day-2 DDNS action hint at the narrowest credential:
  the Dynu IP Update Password, a zone-limited dynv6 HTTP token, and for DuckDNS
  a warning that no restricted token exists. The recommended scoped credential
  for the other providers is in the table; their secrets do not reach the log.
- The residual risk is documented here and in `docs/design/architecture.md`
  (Security layer, known residual risks). Credentials stay in the chmod-600
  `config/ddns-updater/config.json`; they are never written to `.env`.

## Rejected alternatives

- **`LOG_LEVEL` change.** The line is logged at ERROR, the level that is always
  kept. Reproduced with `LOG_LEVEL=error`.
- **Wrap the entrypoint in a `sed` filter.** It would mask the log but not the
  web UI message, and it replaces PID 1, so signals, the image healthcheck and
  the exit code stop reflecting the updater. A fragile layer over an image
  MediaStack does not build.
- **Store a hashed Dynu password in `config.json`.** The hash is as good as the
  password for this API, so a leaked line still lets someone update the IP, and
  it puts a second credential format into the wizard.
- **Pin and patch the image.** The project's premise is low maintenance on
  upstream images; a fork is the opposite.

## Consequences

- A failing Dynu, DuckDNS or dynv6 update can still put that provider's
  secret in the container log until the rotation drops it.
- DuckDNS has no scoped token, so its exposure is the whole account.
- A new provider added to the wizard needs its row in the table: read where
  its `Update` puts the secret before offering it.
- Smaller rotation means `docker logs ddns-updater` holds about 2 MB. That is
  enough for several days of 5-minute cycles.

## Reopen condition

Reopen when upstream adds a redaction setting or stops logging request URLs, or
when MediaStack starts shipping container logs off the host or into a support
bundle.

## Enforcement

Nothing enforces the rotation size: no test pins the `ddns-updater` `logging`
block. The residual risk itself cannot be tested without a live provider
outage.
