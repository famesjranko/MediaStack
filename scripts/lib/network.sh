# Owns: Compatibility entry point and source-time state for shared network helpers.
# Sources: scripts/lib/network/{public,local-probes,dns,ddns,port-gate,access}.sh.

_NET_PUBLIC_IP=""
_NET_DL_MBPS=""
_NET_UL_MBPS=""
declare -A _NET_PORT_STATUS 2>/dev/null || true
_STAGE2_CLOUDFLARE_IPS_V4=""

: "${DDNS_VERIFY_PULL_TIMEOUT_SECONDS:=120}"
: "${DDNS_VERIFY_PORT_PUBLISH_ATTEMPTS:=20}"
: "${DDNS_VERIFY_PORT_PUBLISH_SLEEP_SECONDS:=1}"
: "${DDNS_VERIFY_UPDATE_POLL_ATTEMPTS:=8}"
: "${DDNS_VERIFY_UPDATE_REQUEST_TIMEOUT_SECONDS:=20}"
: "${DDNS_VERIFY_UPDATE_POLL_SLEEP_SECONDS:=1}"
readonly DDNS_VERIFY_PULL_TIMEOUT_SECONDS
readonly DDNS_VERIFY_PORT_PUBLISH_ATTEMPTS DDNS_VERIFY_PORT_PUBLISH_SLEEP_SECONDS
readonly DDNS_VERIFY_UPDATE_POLL_ATTEMPTS DDNS_VERIFY_UPDATE_REQUEST_TIMEOUT_SECONDS
readonly DDNS_VERIFY_UPDATE_POLL_SLEEP_SECONDS

# Image the ephemeral DDNS verification container and its fixed retry delay.
# These are source-time state owned by the compatibility entry point.
_DDNS_VERIFY_IMAGE="qmcgaw/ddns-updater:latest"
_DDNS_VERIFY_RETRY_DELAY=8

_NETWORK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/network" && pwd)"

source "$_NETWORK_LIB_DIR/public.sh"
source "$_NETWORK_LIB_DIR/local-probes.sh"
source "$_NETWORK_LIB_DIR/dns.sh"
source "$_NETWORK_LIB_DIR/ddns.sh"
source "$_NETWORK_LIB_DIR/port-gate.sh"
source "$_NETWORK_LIB_DIR/access.sh"
