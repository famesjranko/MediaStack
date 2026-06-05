# =============================================================================
# MediaStack validators — Stage 1 input contracts
# =============================================================================
# Sourced by wizard/setup flows. Each validate_* function returns 0 on valid
# input and non-zero on invalid input. Invalid input emits exactly one
# ui_log warn message before returning.

_validators_port_process_name() {
    local ss_output="$1"
    printf '%s\n' "$ss_output" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1
}

_validators_wireguard_port_is_mediastack() {
    local value="$1"
    local rows row name ports

    [[ "${WG_PORT:-}" == "$value" ]] || return 1
    command -v docker >/dev/null 2>&1 || return 1

    rows=$(docker ps --filter name=wireguard --format '{{.Names}} {{.Ports}}' 2>/dev/null || true)
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        name="${row%% *}"
        ports="${row#* }"
        [[ "$name" == "wireguard" ]] || continue
        case "$ports" in
            *":${value}->"*"/udp"*|*"${value}/udp"*) return 0 ;;
        esac
    done <<< "$rows"

    return 1
}

validate_admin_user() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "Admin username is required."
        return 1
    fi
    if [[ "$value" == *\'* ]]; then
        ui_log warn "Admin username cannot contain a single quote (')."
        return 1
    fi
    if ! [[ "$value" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        ui_log warn "Admin username must be 3-32 chars: letters, digits, _ or -."
        return 1
    fi
    return 0
}

validate_admin_email() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "Admin email is required for SSL certs and service login."
        return 1
    fi
    # Defense in depth alongside .env single-quoting: reject characters that
    # would let user input escape the single-quoted NPM_ADMIN_EMAIL line in
    # .env (single quote) or break parsers (whitespace, $, backtick, ;).
    if [[ "$value" == *\'* ]]; then
        ui_log warn "Email cannot contain a single quote (')."
        return 1
    fi
    if [[ "$value" =~ [[:space:]\$\`\;\\] ]]; then
        ui_log warn "Email cannot contain whitespace or shell-special characters (\$, backtick, ;, backslash)."
        return 1
    fi
    local lc="${value,,}"
    if [[ "$lc" =~ @(example\.com|example\.net|example\.org)$ ]]; then
        ui_log warn "Example email domains are rejected by Let's Encrypt - please use a real email."
        return 1
    fi
    if ! [[ "$value" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        ui_log warn "Email must be in the form 'user@domain.tld'."
        return 1
    fi
    # Reject 1-char TLDs — RFC requires 2+ and Let's Encrypt rejects them.
    # Catches the bad email at Stage 1 collection time rather than letting
    # it ride silently until Stage 2's NPM cert request fails (by which
    # point the user has forgotten what they typed).
    local domain_part="${value#*@}"
    local tld="${domain_part##*.}"
    if (( ${#tld} < 2 )); then
        ui_log warn "Email TLD must be at least 2 characters (e.g. 'com', 'net')."
        return 1
    fi
    return 0
}

validate_admin_password() {
    local value="$1"
    if [[ "$value" == *\'* ]]; then
        ui_log warn "Password cannot contain a single quote (')."
        return 1
    fi
    # Floor is 12 to match Portainer's enforced minimum (Portainer 2.20+
    # rejects passwords <12 chars at admin/init with HTTP 400). MediaStack
    # uses one shared admin password across services, so the wizard's floor
    # must be the strictest of any service we provision.
    if (( ${#value} < 12 )); then
        ui_log warn "Password must be at least 12 characters (Portainer requires this)."
        return 1
    fi
    return 0
}

validate_ddns_credential() {
    local label="${1:-DDNS credential}"
    local value="${2:-}"
    # Reject empty AND all-whitespace: stage2 trims the stored value, so an
    # all-spaces entry would collapse to "" and fail Dynu auth without a prompt.
    if [[ -z "${value//[[:space:]]/}" ]]; then
        ui_log warn "$label is required."
        return 1
    fi
    if [[ "$value" == *\'* ]]; then
        ui_log warn "$label cannot contain a single quote (')."
        return 1
    fi
    return 0
}

validate_ddns_username() {
    validate_ddns_credential "Dynu username" "$1"
}

validate_ddns_password() {
    validate_ddns_credential "Dynu password" "$1"
}

# Whole-number Mbps (upload bandwidth used to size the streaming table). Kept
# integer because the value is fed to python int() in the bitrate recommendation.
validate_mbps_whole() {
    [[ "$1" =~ ^[0-9]+$ ]] && return 0
    ui_log warn "Enter your upload speed as a whole number of Mbps (e.g. 100)."
    return 1
}

# Mbps allowing one decimal place (per-viewer streaming cap; 0 = unlimited).
validate_mbps_decimal() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && return 0
    ui_log warn "Enter a number in Mbps (decimals OK, e.g. 3.5; 0 = unlimited)."
    return 1
}

# MB/s (megabytes/sec) allowing decimals — qBittorrent download/upload speed
# limits; 0 = unlimited. Single source for both Stage 1's install prompt
# (_stage1_read_limit) and the day-2 "Adjust bandwidth limits" launcher action,
# so the grammar and the unit-correct "MB/s" copy never drift. Distinct from
# validate_mbps_decimal (megabits — the Jellyfin streaming cap), whose "Mbps"
# message would mislabel this byte-rate field.
validate_mb_per_sec() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && return 0
    ui_log warn "Enter a number in MB/s (0 = unlimited)."
    return 1
}

validate_data_dir() {
    local path="$1"
    if [[ -z "$path" ]]; then
        ui_log warn "Data directory path is required."
        return 1
    fi
    # Whitelist: letters, digits, '/', '.', '_', '-'. Anything else (single
    # quotes, $, backtick, ;, =, whitespace, newlines, ...) is rejected.
    # This subsumes the BL-01 shell-metacharacter guard and additionally
    # blocks characters that silently corrupt downstream parsers:
    #   - '='     breaks awk -F= in _resolve_data_partition / .env parsers
    #   - newline breaks 'awk NR==2' parse of df output and .env line itself
    #   - trailing whitespace silently mismatches '[[ -d "$DATA_DIR" ]]'
    # The whitelist is conservative for a non-technical-user audience whose
    # paths are realistically /data, /srv/media, /mnt/storage, etc.
    if [[ "$path" =~ [^a-zA-Z0-9._/\-] ]]; then
        ui_log warn "Data directory may only contain letters, digits, '.', '_', '-', and '/'."
        return 1
    fi
    if [[ "$path" != /* ]]; then
        ui_log warn "Data directory must be an absolute path (start with '/')."
        return 1
    fi
    if [[ "$path" =~ ^/media/ ]]; then
        ui_log warn "$path looks like a removable mount point. Choose a path outside /media/."
        return 1
    fi

    if [[ ! -e "$path" ]]; then
        if ! ui_confirm "Path $path does not exist. Create it?" "yes"; then
            ui_log warn "Data directory $path not created - pick a different path or allow creation."
            return 1
        fi
        # Try unprivileged mkdir first (works for paths under $HOME etc.).
        # Fall back to sudo for system paths like /data, /srv/media, /mnt/storage
        # whose root-owned parents need elevation. Chown back to the current
        # user so MediaStack containers (which run as the host UID/GID) can
        # write into it without further permission gymnastics.
        if mkdir -p "$path" 2>/dev/null; then
            :
        elif sudo mkdir -p "$path" 2>/dev/null && sudo chown "$(id -un):$(id -gn)" "$path" 2>/dev/null; then
            ui_log info "Created $path (root-owned parent - used sudo to create + chown to $(id -un))."
        else
            ui_log warn "Could not create $path (read-only parent or permission denied)."
            return 1
        fi
    fi

    if [[ ! -d "$path" ]]; then
        ui_log warn "$path exists but is not a directory."
        return 1
    fi
    if [[ ! -w "$path" ]]; then
        ui_log warn "$path is not writable by user $(id -un)."
        return 1
    fi

    local opts
    opts=$(findmnt -no OPTIONS --target "$path" 2>/dev/null)
    if [[ ",$opts," == *,ro,* ]]; then
        ui_log warn "$path is on a read-only filesystem."
        return 1
    fi

    local free_gb
    free_gb=$(df -BG "$path" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
    if [[ -z "$free_gb" ]]; then
        ui_log warn "Could not read free space on $path (df returned no output)."
        return 1
    fi
    # PRE-01 already warned-but-continued for the resolved data partition at
    # startup. The validator's disk floor is a parallel safety net that fires
    # when the user picks a custom path. Match PRE-01's behavior: warn + ask
    # for explicit confirmation, rather than silently looping the prompt.
    if (( free_gb < 30 )); then
        ui_log warn "$path has only ${free_gb}GB free - recommended minimum is 30GB."
        if ! ui_confirm "Continue anyway?" "yes"; then
            ui_log warn "Pick a different path with more free space, or free up space on $path."
            return 1
        fi
        ui_log info "Continuing with ${free_gb}GB free at $path (below 30GB recommended)."
    fi
    return 0
}

validate_nas_mountpoint() {
    local path="$1"
    if [[ -z "$path" ]]; then
        ui_log warn "NAS mountpoint path is required."
        return 1
    fi
    if [[ "$path" =~ [^a-zA-Z0-9._/\-] ]]; then
        ui_log warn "NAS mountpoint may only contain letters, digits, '.', '_', '-', and '/'."
        return 1
    fi
    if [[ "$path" != /* ]]; then
        ui_log warn "NAS mountpoint must be an absolute path (start with '/')."
        return 1
    fi
    if [[ "$path" == "/" ]]; then
        ui_log warn "NAS mountpoint cannot be '/'."
        return 1
    fi
    if [[ "$path" =~ ^/media/ ]]; then
        ui_log warn "$path looks like a removable mount point. Choose a path outside /media/."
        return 1
    fi

    if [[ ! -e "$path" ]]; then
        if ! ui_confirm "Mountpoint $path does not exist. Create it?" "yes"; then
            ui_log warn "NAS mountpoint $path not created - pick a different path or allow creation."
            return 1
        fi
        if mkdir -p "$path" 2>/dev/null; then
            :
        elif sudo mkdir -p "$path" 2>/dev/null; then
            ui_log info "Created NAS mountpoint $path with sudo."
        else
            ui_log warn "Could not create NAS mountpoint $path (read-only parent or permission denied)."
            return 1
        fi
    fi

    if [[ ! -d "$path" ]]; then
        ui_log warn "$path exists but is not a directory."
        return 1
    fi
    return 0
}

validate_nfs_host() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "NAS host/IP is required."
        return 1
    fi
    if [[ "$value" =~ [^a-zA-Z0-9._:\-] ]]; then
        ui_log warn "NAS host/IP may only contain letters, digits, '.', ':', '_', and '-'."
        return 1
    fi
    # Dotted-quad IPv4: bound each octet to <= 255 (same shape check as
    # validate_wireguard_hostname) so 999.999.999.999 is rejected up front.
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local octet; local -a octets
        IFS='.' read -ra octets <<< "$value"
        for octet in "${octets[@]}"; do
            # 10# forces base-10 so a leading-zero octet (08/09) isn't read as octal.
            if (( 10#$octet > 255 )); then
                ui_log warn "NAS IP has an octet over 255 (expected e.g. 192.168.1.10)."
                return 1
            fi
        done
        return 0
    fi
    # All-numeric with dots but not a 4-octet quad => a partial/malformed IP
    # (e.g. 192.168.1) the user almost certainly mistyped.
    if [[ "$value" =~ ^[0-9.]+$ ]]; then
        ui_log warn "That looks like an incomplete IP address - enter a full IPv4 (e.g. 192.168.1.10) or a hostname."
        return 1
    fi
    # Hostname/FQDN: reject a leading/trailing dot or an empty label. Single-label
    # LAN names (e.g. 'nas') and dotted names (nas.local) are both allowed.
    if [[ "$value" == .* || "$value" == *. || "$value" == *..* ]]; then
        ui_log warn "NAS hostname has a misplaced dot (no leading/trailing dot or empty label)."
        return 1
    fi
    return 0
}

validate_nfs_export() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "NFS export path is required."
        return 1
    fi
    if [[ "$value" != /* ]]; then
        ui_log warn "NFS export must be an absolute path (start with '/')."
        return 1
    fi
    if [[ "$value" =~ [[:space:]\'\`\"\$\\\;] ]]; then
        ui_log warn "NFS export cannot contain whitespace, quotes, or shell-special characters."
        return 1
    fi
    return 0
}

validate_nfs_options() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "NFS mount options are required."
        return 1
    fi
    if [[ "$value" =~ [[:space:]\'\`\"\$\\\;] ]]; then
        ui_log warn "NFS mount options cannot contain whitespace, quotes, or shell-special characters."
        return 1
    fi
    if [[ "$value" =~ [^a-zA-Z0-9.,=_:/\-] ]]; then
        ui_log warn "NFS mount options may only contain letters, digits, '.', ',', '=', '_', ':', '/', and '-'."
        return 1
    fi
    return 0
}

validate_storage_sentinel() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "Storage sentinel path is required."
        return 1
    fi
    if [[ "$value" != /* ]]; then
        ui_log warn "Storage sentinel must be an absolute path."
        return 1
    fi
    if [[ "$value" =~ [[:space:]\'\`\"\$\\\;] ]]; then
        ui_log warn "Storage sentinel cannot contain whitespace, quotes, or shell-special characters."
        return 1
    fi
    return 0
}

validate_torrent_port() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "qBittorrent peer port is required."
        return 1
    fi
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        ui_log warn "qBittorrent peer port must be numeric."
        return 1
    fi
    if (( value < 1 || value > 65535 )); then
        ui_log warn "qBittorrent peer port must be between 1 and 65535."
        return 1
    fi

    local ss_output process_name
    ss_output=$(sudo ss -lntp "sport = :$value" 2>/dev/null | awk 'NR > 1 {print}')
    if [[ -n "$ss_output" ]]; then
        process_name=$(_validators_port_process_name "$ss_output")
        if [[ -n "$process_name" ]]; then
            ui_log warn "Port $value is in use by $process_name. Pick a different port."
        else
            ui_log warn "Port $value is already in use. Pick a different port."
        fi
        return 1
    fi
    return 0
}

validate_domain_name() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "Domain name is required."
        return 1
    fi

    local lc="${value,,}"
    if [[ "$lc" == "localhost" || "$lc" == *".localhost" ]]; then
        ui_log warn "Use a real domain name, not localhost."
        return 1
    fi
    case "$lc" in
        example.com|*.example.com|example.org|*.example.org|example.net|*.example.net|example.edu|*.example.edu)
            ui_log warn "$value is a reserved example domain (RFC 2606) - enter your real domain."
            return 1
            ;;
        test|*.test|invalid|*.invalid)
            ui_log warn "$value is a reserved test/invalid domain (RFC 6761)."
            return 1
            ;;
    esac
    if (( ${#value} > 253 )); then
        ui_log warn "Domain name is too long."
        return 1
    fi
    if [[ "$value" != *.* || "$value" == *".."* || "$value" == *"_"* ]]; then
        ui_log warn "Domain must be a normal FQDN such as media.example.com."
        return 1
    fi

    local label
    IFS='.' read -ra labels <<< "$value"
    for label in "${labels[@]}"; do
        if [[ -z "$label" || ${#label} -gt 63 ]]; then
            ui_log warn "Domain labels must be 1-63 characters."
            return 1
        fi
        if ! [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
            ui_log warn "Domain labels may contain only letters, digits, and interior hyphens."
            return 1
        fi
    done
    return 0
}

validate_wireguard_hostname() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "WireGuard hostname is required."
        return 1
    fi
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local octet
        IFS='.' read -ra octets <<< "$value"
        for octet in "${octets[@]}"; do
            if (( octet > 255 )); then
                ui_log warn "WireGuard IPv4 address is invalid."
                return 1
            fi
        done
        return 0
    fi
    validate_domain_name "$value"
}

validate_wireguard_port() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "WireGuard UDP port is required."
        return 1
    fi
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        ui_log warn "WireGuard UDP port must be numeric."
        return 1
    fi
    if (( value < 1 || value > 65535 )); then
        ui_log warn "WireGuard UDP port must be between 1 and 65535."
        return 1
    fi

    local ss_output process_name
    ss_output=$(sudo ss -lntu "sport = :$value" 2>/dev/null | awk 'NR > 1 {print}')
    if [[ -n "$ss_output" ]]; then
        process_name=$(_validators_port_process_name "$ss_output")
        if _validators_wireguard_port_is_mediastack "$value"; then
            ui_log info "WireGuard UDP port $value is already in use by MediaStack wireguard - reusing it."
            return 0
        fi
        if [[ -n "$process_name" ]]; then
            ui_log warn "WireGuard UDP port $value is in use by $process_name. Pick a different port."
        else
            ui_log warn "WireGuard UDP port $value is already in use. Pick a different port."
        fi
        return 1
    fi
    return 0
}

validate_smb_port() {
    local value="${1:-445}"
    local ss_output process_name
    ss_output=$(sudo ss -lntp "sport = :$value" 2>/dev/null | awk 'NR > 1 {print}')
    if [[ -z "$ss_output" ]]; then
        return 0
    fi
    process_name=$(_validators_port_process_name "$ss_output")
    # smbd on 445 IS MediaStack's SMB share — not a conflict. setup_samba()
    # will (re)write /etc/samba/smb.conf with the MEDIASTACK marker block
    # idempotently. This makes re-runs idempotent: once SMB is enabled and
    # smbd is running, the wizard re-run path doesn't false-flag it.
    if [[ "$process_name" == "smbd" ]]; then
        ui_log info "Port 445 in use by smbd - MediaStack will manage it."
        return 0
    fi
    if [[ -n "$process_name" ]]; then
        ui_log warn "Port 445 is in use by $process_name (not samba). Disable SMB or free the port."
    else
        ui_log warn "Port 445 is already in use. Disable SMB or free the port."
    fi
    return 1
}

validate_lan_cidr() {
    local value="$1"
    local rc
    if [[ -z "$value" ]]; then
        ui_log warn "LAN CIDR is required (e.g. 192.168.1.0/24)."
        return 1
    fi
    # Python `is_private` is too permissive — it also accepts loopback,
    # link-local, TEST-NET, CGNAT, etc. Home LANs are RFC1918 only.
    python3 -c '
import sys, ipaddress
try:
    n = ipaddress.IPv4Network(sys.argv[1], strict=False)
except Exception:
    sys.exit(2)
rfc1918 = (
    ipaddress.IPv4Network("10.0.0.0/8"),
    ipaddress.IPv4Network("172.16.0.0/12"),
    ipaddress.IPv4Network("192.168.0.0/16"),
)
if not any(n.subnet_of(r) for r in rfc1918):
    sys.exit(3)
' "$value" 2>/dev/null
    rc=$?
    if (( rc != 0 )); then
        case "$rc" in
            2) ui_log warn "'$value' is not a valid IPv4 CIDR (try '192.168.1.0/24')." ;;
            3) ui_log warn "'$value' is not an RFC1918 LAN range - use 10/8, 172.16/12, or 192.168/16." ;;
            *) ui_log warn "Invalid LAN CIDR '$value'." ;;
        esac
        return 1
    fi
    return 0
}

validate_timezone() {
    local value="$1"
    if [[ -z "$value" ]]; then
        ui_log warn "Timezone is required."
        return 1
    fi
    # Require a regular file under /usr/share/zoneinfo (-f, not -e). The
    # zoneinfo tree includes auxiliary metadata files (zone.tab, posixrules,
    # leapseconds, ...) which pass -e but are NOT valid TZ values — Glibc's
    # tzset can't parse them and every timezone-sensitive container would
    # silently misbehave hours later. -f also rules out passing a bare
    # directory name like 'Etc' (which is a directory, not a leaf).
    if [[ ! -f "/usr/share/zoneinfo/$value" ]]; then
        ui_log warn "Timezone '$value' was not found under /usr/share/zoneinfo."
        return 1
    fi
    case "$value" in
        zone.tab|zone1970.tab|iso3166.tab|leapseconds|posixrules|tzdata.zi|leap-seconds.list)
            ui_log warn "'$value' is a tzdata metadata file, not a timezone. Try 'America/New_York' or 'Etc/UTC'."
            return 1
            ;;
    esac
    return 0
}

validate_subtitle_langs() {
    # Bazarr subtitle languages. The wizard value flows verbatim into
    # config.yml bazarr.languages, and bazarr/main.sh does a CASE-SENSITIVE
    # LANG_MAP.get(lang) over the lowercase keys below — so a typo ('englsih'),
    # an unsupported name ('klingon'), or a capitalised entry ('English', which
    # the prompt's lowercase example never warns against) is silently dropped.
    # If every token misses, the language profile ends up empty and subtitles
    # never download, with no error anywhere. Reject unknown tokens here so the
    # wizard re-prompts on the TTY path; the call site lowercases the accepted
    # value before storing it (this validator only returns 0/1, it cannot
    # transform the captured value).
    #
    # Canonical key list: scripts/services/bazarr/main.sh LANG_MAP. The two
    # copies are kept in sync by the drift guard in tests/unit/validators.sh.
    local value="$1"
    local supported="english spanish french german portuguese dutch italian japanese chinese korean arabic russian swedish norwegian danish finnish polish turkish hindi"

    local -a tokens=()
    # read -ra splits on the comma without pathname expansion (a bare '*' in
    # the input must not glob). Matches wizard_apply.py: split(',').
    IFS=',' read -ra tokens <<< "$value"

    local -a bad=()
    local count=0 tok known s
    for tok in "${tokens[@]}"; do
        # Trim surrounding whitespace and lowercase — mirrors wizard_apply.py's
        # per-token .strip() and Bazarr's lowercase LANG_MAP keys.
        tok="${tok#"${tok%%[![:space:]]*}"}"
        tok="${tok%"${tok##*[![:space:]]}"}"
        tok="${tok,,}"
        [[ -z "$tok" ]] && continue
        count=$((count + 1))
        # Exact match against each supported key. A space-padded substring test
        # would be fooled twice: 'dan' would match 'danish', and a token with an
        # internal space like 'english spanish' would match two consecutive
        # entries in the space-delimited set. Exact equality avoids both.
        known=0
        for s in $supported; do
            [[ "$tok" == "$s" ]] && { known=1; break; }
        done
        (( known )) || bad+=("$tok")
    done

    if (( count == 0 )); then
        ui_log warn "Enter at least one subtitle language (e.g. english,spanish). Supported: ${supported// /, }."
        return 1
    fi
    if (( ${#bad[@]} > 0 )); then
        ui_log warn "Unsupported subtitle language(s): ${bad[*]}. Supported: ${supported// /, }."
        return 1
    fi
    return 0
}
