# Owns: Bandwidth field validators (Mbps whole/decimal, MB/s).
# Sources: scripts/lib/validators.sh state; sourced by scripts/lib/validators.sh.


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

