#!/usr/bin/env bash
# Owns: npm_* — deploy renewed certificates to the running NPM nginx workers.
# Sources: Certbot's deploy-hook lifecycle inside the NPM container; nginx on PATH.

set -euo pipefail

# Both API and timer renewals use Certbot. Reload only after successful issuance
# and validation, so nginx keeps serving its current configuration on failure.
nginx -t
nginx -s reload
