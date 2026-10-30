"""Check the product busy probe against Certbot's real lock in disposable NPM."""

import select
import subprocess

HOLDER = r"""
import os
import re
import select
import sys
from pathlib import Path
from certbot._internal import lock

# Read the image's setting independently of the product probe. A changed NPM
# work directory must fail this test until the product supports it.
source = Path('/app/internal/certificate.js').read_text()
match = re.search(r'const certbotWorkDir\s*=\s*"([^"]+)";', source)
if match is None:
    raise RuntimeError('Cannot determine NPM Certbot work directory')
work_dir = match[1]
os.makedirs(work_dir, exist_ok=True)
held = lock.lock_dir(work_dir)
try:
    print('locked', flush=True)
    select.select([sys.stdin], [], [], 45)
finally:
    held.release()
"""


def require_probe(expected: int) -> None:
    result = subprocess.run(
        ["bash", "-c", "source scripts/services/npm/certs.sh; _npm_certbot_busy"],
        check=False,
        timeout=10,
    )
    if result.returncode != expected:
        raise RuntimeError(f"Certbot probe: expected {expected}, got {result.returncode}")


def main() -> None:
    # Given NPM has no active issuance.
    # When the production probe runs against its real container.
    # Then the lock is absent, distinct from a failed Docker execution.
    require_probe(10)

    # Given Certbot holds NPM's configured work-directory lock.
    # Bypass the trace shim for fixture setup; only the product probe is evidence.
    with subprocess.Popen(
        ["/usr/bin/docker", "exec", "-i", "npm", "/opt/certbot/bin/python", "-c", HOLDER],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as holder:
        try:
            if holder.stdout is None or not select.select([holder.stdout], [], [], 15)[0]:
                raise RuntimeError("Certbot lock holder did not become ready")
            if holder.stdout.readline().strip() != "locked":
                raise RuntimeError("Certbot could not acquire its work-directory lock")

            # When the production probe runs while that lock is held.
            # Then it reports busy and prevents another issuance request.
            require_probe(0)
        finally:
            holder.communicate("release\n", timeout=50)
        if holder.returncode != 0:
            raise RuntimeError(f"Certbot lock holder exited {holder.returncode}")

    # Given Certbot has released its lock.
    # When the production probe runs again.
    # Then issuance is permitted again.
    require_probe(10)
    print("Certbot lock probe: idle=10, busy=0, released=10", flush=True)


if __name__ == "__main__":
    main()
