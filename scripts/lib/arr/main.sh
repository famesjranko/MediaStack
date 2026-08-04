# Owns: Compatibility entry point for all shared Sonarr/Radarr helpers.
# Sources: scripts/lib/arr/{quality,formats,indexers,storage,connections}.sh after lib/common.sh.

# Absolute path to this lib's directory — used to locate render/ and templates/.
_ARR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$_ARR_LIB_DIR/quality.sh"
source "$_ARR_LIB_DIR/formats.sh"
source "$_ARR_LIB_DIR/indexers.sh"
source "$_ARR_LIB_DIR/storage.sh"
source "$_ARR_LIB_DIR/connections.sh"
