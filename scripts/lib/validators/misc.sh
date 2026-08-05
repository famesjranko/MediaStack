# Owns: Timezone and subtitle-language validators.
# Sources: scripts/lib/validators.sh state; sourced by scripts/lib/validators.sh.

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
        zone.tab | zone1970.tab | iso3166.tab | leapseconds | posixrules | tzdata.zi | leap-seconds.list)
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
    IFS=',' read -ra tokens <<<"$value"

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
            [[ "$tok" == "$s" ]] && {
                known=1
                break
            }
        done
        ((known)) || bad+=("$tok")
    done

    if ((count == 0)); then
        ui_log warn "Enter at least one subtitle language (e.g. english,spanish). Supported: ${supported// /, }."
        return 1
    fi
    if ((${#bad[@]} > 0)); then
        ui_log warn "Unsupported subtitle language(s): ${bad[*]}. Supported: ${supported// /, }."
        return 1
    fi
    return 0
}
