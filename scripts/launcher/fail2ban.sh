#!/usr/bin/env bash
# Owns: The day-2 fail2ban menu, ban actions, statistics, and whitelist management.
# Sources: launcher globals, .env, scripts/lib/ui.sh, setup/fail2ban.sh, and Docker helpers.

submenu_fail2ban() {
    if ! declare -F _health_f2b_running >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/scripts/lib/health.sh"
    fi
    if ! _docker_reachable; then
        echo ""
        ui_log warn "Docker isn't reachable - start the stack first."
        launcher_pause_for_menu
        return 0
    fi
    if ! _health_f2b_running; then
        echo ""
        ui_log info "fail2ban isn't running. It only runs when you have a domain / remote access set up; LAN-only installs don't expose services to the internet, so there's nothing to protect."
        launcher_pause_for_menu
        return 0
    fi
    while true; do
        clear
        # Live quick-stats, recomputed each loop like the Manage Stack / Diagnostics
        # banners - the banner is the whole 1 + J exec budget (_f2b_banned_now_summary).
        local wl_def wl_cus
        read -r wl_def wl_cus < <(_f2b_wl_counts)
        ui_box "MediaStack - Manage fail2ban" \
            "$(ui_kv 'Protects' 'Jellyfin, NPM and Seerr logins from brute force')" \
            "$(ui_kv 'Banned now' "$(_f2b_banned_now_summary)")" \
            "$(ui_kv 'Whitelist' "$wl_def defaults + $wl_cus custom")"
        echo ""
        local choice
        choice=$(ui_choose "fail2ban:" \
            "Banned IPs" \
            "Whitelist (always-allow IPs)" \
            "Jail stats & history" \
            "Back")
        case "$choice" in
            "Banned IPs"*) f2b_banned_menu ;;
            "Whitelist"*) f2b_whitelist_menu ;;
            "Jail stats"*) f2b_stats_menu ;;
            *) return 0 ;;
        esac
    done
}

f2b_banned_menu() {
    local page=0 PAGE=15
    while true; do
        clear
        local pairs ip ips=()
        pairs=$(_f2b_banned_pairs)
        while IFS= read -r ip; do [[ -n "$ip" ]] && ips+=("$ip"); done < <(cut -f2 <<<"$pairs" | sort -u)
        local count=${#ips[@]}
        ui_box "MediaStack - Banned IPs" \
            "$(ui_kv 'Banned now' "$count")" \
            "$(ui_kv 'Note' 'a ban blocks ALL services, not just the jail that fired')"
        echo ""
        if ((count == 0)); then
            ui_log info "No IPs are currently banned."
            echo ""
            ui_choose "Banned IPs:" "Back" >/dev/null
            return 0
        fi
        # Clamp the page in case unbans shrank the list since the last draw.
        ((page * PAGE >= count)) && page=0
        local start=$((page * PAGE)) end=$((page * PAGE + PAGE))
        ((end > count)) && end=$count
        local rows=() i jl
        for ((i = start; i < end; i++)); do
            # Join this IP's jails from the pairs (an attacker banned in jellyfin+npm
            # is ONE row, jails listed together).
            jl=$(awk -v t="${ips[$i]}" '$2==t{printf "%s%s", sep, $1; sep=", "}' <<<"$pairs")
            rows+=("${ips[$i]}  ($jl)")
        done
        local remaining=$((count - end))
        ((remaining > 0)) && rows+=("Show more ($remaining remaining)")
        ((page > 0)) && rows+=("Back to first page")
        # Bulk release for the scanner-storm case (40 one-at-a-time picks is not a
        # UI). Only offered when there's more than one IP - with a single ban the
        # per-IP actions already cover it. Every page carries the item.
        ((count > 1)) && rows+=("Unban all ($count IPs)")
        rows+=("Back")
        local prompt="Pick an IP to act on"
        ((count > PAGE)) && prompt+="  (showing $((start + 1))–$end of $count)"
        local choice
        choice=$(ui_choose "$prompt:" "${rows[@]}")
        # The usual bare "Back"* glob would swallow "Back to first page"; match the
        # paging/bulk arms (and plain Back exactly) BEFORE any glob could.
        case "$choice" in
            "Show more"*) page=$((page + 1)) ;;
            "Back to first page") page=0 ;;
            "Unban all"*)
                if ui_confirm "Unban all $count IPs? (each can be re-banned on its next failed login)" "no"; then
                    local out rc
                    out=$(docker exec fail2ban fail2ban-client unban --all 2>&1)
                    rc=$?
                    if ((rc == 0)); then
                        _show_action_result 0 "Unban all ($count IPs)"
                    else
                        ui_log warn "Couldn't unban all: ${out:-fail2ban error}"
                    fi
                else
                    ui_log info "Cancelled - nothing changed."
                fi
                launcher_pause_for_menu
                ;;
            "Back") return 0 ;;
            *) f2b_ip_actions "${choice%%  (*}" ;;
        esac
    done
}

f2b_ip_actions() {
    local ip="$1"
    clear
    local jl
    jl=$(awk -v t="$ip" '$2==t{printf "%s%s", sep, $1; sep=", "}' <<<"$(_f2b_banned_pairs)")
    [[ -z "$jl" ]] && jl="(no longer banned)"
    ui_box "MediaStack - Banned IP $ip" \
        "$(ui_kv 'IP' "$ip")" \
        "$(ui_kv 'Banned by' "$jl")" \
        "$(ui_kv 'Note' 'a ban blocks ALL services, not just the jail that fired')"
    echo ""
    local choice
    choice=$(ui_choose "What would you like to do?" \
        "Unban (restores all access)" \
        "Unban + always allow (won't be banned again)" \
        "Back")
    # BOTH labels start with "Unban " - a bare "Unban"* glob would route the
    # always-allow action to plain unban and silently drop the whitelist step. Match
    # the specific label FIRST; anchor plain unban on "Unban (". f2b_whitelist_apply
    # already unbans on add and runs its OWN ui_confirm - no second confirm here.
    case "$choice" in
        "Unban + always"*)
            f2b_whitelist_apply add "$ip" "$SCRIPT_DIR/config/fail2ban/jail.d/mediastack.conf"
            launcher_pause_for_menu
            ;;
        "Unban ("*)
            f2b_do_unban "$ip"
            launcher_pause_for_menu
            ;;
        *) return 0 ;;
    esac
}

f2b_stats_menu() {
    while true; do
        clear
        local status jails
        status=$(docker exec fail2ban fail2ban-client status 2>/dev/null | tr -d '\r')
        [[ -z "$status" ]] && {
            echo ""
            ui_log warn "Couldn't read fail2ban status - is the container up?"
            launcher_pause_for_menu
            return 0
        }
        jails=$(sed -n 's/.*Jail list:[[:space:]]*//p' <<<"$status" | tr ',' ' ')
        local j lines=() all_ips=() all_total=0 jail_csv="" ip
        for j in $jails; do
            local jstat now tot iplist
            jstat=$(docker exec fail2ban fail2ban-client status "$j" 2>/dev/null | tr -d '\r')
            now=$(sed -n 's/.*Currently banned:[[:space:]]*//p' <<<"$jstat" | head -1)
            [[ "$now" =~ ^[0-9]+$ ]] || now=0
            tot=$(sed -n 's/.*Total banned:[[:space:]]*//p' <<<"$jstat" | head -1)
            [[ "$tot" =~ ^[0-9]+$ ]] || tot=0
            iplist=$(sed -n 's/.*Banned IP list:[[:space:]]*//p' <<<"$jstat" | head -1)
            lines+=("$j: $now banned now ($tot total)")
            all_total=$((all_total + tot))
            for ip in $iplist; do all_ips+=("$ip"); done
            jail_csv+="${jail_csv:+, }$j"
        done
        # Distinct across jails: an IP banned in two jails is ONE banned address.
        local distinct
        distinct=$(printf '%s\n' "${all_ips[@]+"${all_ips[@]}"}" | sort -u | grep -c .)
        ui_box "MediaStack - Jail stats & history" \
            "$(ui_kv 'Jails' "$jail_csv")" \
            "$(ui_kv 'Banned now' "$distinct")" \
            "$(ui_kv 'Bans all-time' "$all_total")"
        echo ""
        local l
        for l in "${lines[@]+"${lines[@]}"}"; do ui_log info "$l"; done
        ui_log info "For filter/regex health, use Health & security -> fail2ban protection (regex + jails)."
        echo ""
        local choice
        choice=$(ui_choose "View a jail in detail?" $jails "Recent ban history" "Back")
        case "$choice" in
            "Recent ban history"*)
                f2b_show_recent
                launcher_pause_for_menu
                ;;
            "Back") return 0 ;;
            *) f2b_jail_detail "$choice" ;;
        esac
    done
}

f2b_jail_detail() {
    local jail="$1"
    while true; do
        clear
        local jstat
        jstat=$(docker exec fail2ban fail2ban-client status "$jail" 2>/dev/null | tr -d '\r')
        if [[ -z "$jstat" ]]; then
            echo ""
            ui_log warn "Couldn't read status for $jail."
            launcher_pause_for_menu
            return 0
        fi
        local now tot fnow ftot files iplist
        now=$(sed -n 's/.*Currently banned:[[:space:]]*//p' <<<"$jstat" | head -1)
        [[ "$now" =~ ^[0-9]+$ ]] || now=0
        tot=$(sed -n 's/.*Total banned:[[:space:]]*//p' <<<"$jstat" | head -1)
        [[ "$tot" =~ ^[0-9]+$ ]] || tot=0
        fnow=$(sed -n 's/.*Currently failed:[[:space:]]*//p' <<<"$jstat" | head -1)
        [[ "$fnow" =~ ^[0-9]+$ ]] || fnow=0
        ftot=$(sed -n 's/.*Total failed:[[:space:]]*//p' <<<"$jstat" | head -1)
        [[ "$ftot" =~ ^[0-9]+$ ]] || ftot=0
        files=$(sed -n 's/.*File list:[[:space:]]*//p' <<<"$jstat" | head -1)
        iplist=$(sed -n 's/.*Banned IP list:[[:space:]]*//p' <<<"$jstat" | head -1)
        ui_box "MediaStack - Jail detail: $jail" \
            "$(ui_kv 'Banned now' "$now")" \
            "$(ui_kv 'Banned total' "$tot")" \
            "$(ui_kv 'Failed logins' "$fnow recent ($ftot total)")" \
            "$(ui_kv 'Watching' "$files")"
        echo ""
        local ips=() ip
        for ip in $iplist; do ips+=("$ip"); done
        if ((${#ips[@]} == 0)); then
            ui_log info "No IPs banned by this jail right now."
        else
            ui_log info "Banned IPs (pick to act):"
        fi
        echo ""
        local choice
        choice=$(ui_choose "$jail:" "${ips[@]+"${ips[@]}"}" "Back")
        case "$choice" in
            "Back") return 0 ;;
            *) f2b_ip_actions "$choice" ;;
        esac
    done
}

f2b_whitelist_menu() {
    local jail_file="$SCRIPT_DIR/config/fail2ban/jail.d/mediastack.conf"
    while true; do
        clear
        local content line tok toks=() opts=() removable=() wl_def wl_cus
        content=$(cat "$jail_file" 2>/dev/null)
        [[ -z "$content" ]] && content=$(sudo -n cat "$jail_file" 2>/dev/null)
        read -r wl_def wl_cus < <(_f2b_wl_counts)
        ui_box "MediaStack - Whitelist (always allow)" \
            "$(ui_kv 'Always-allow' 'these IPs/ranges are never banned')" \
            "$(ui_kv 'Entries' "$wl_def defaults (locked) + $wl_cus custom")"
        echo ""
        if [[ -z "$content" ]]; then
            ui_log warn "Couldn't read $jail_file - whitelist can't be shown."
            launcher_pause_for_menu
            return 0
        fi
        line=$(grep -m1 '^ignoreip[[:space:]]*=' <<<"$content")
        # Classify each token by EXACT equality against the defaults; render the
        # defaults locked (no Remove) and each user-added token as a Remove choice.
        # Split glob-safe (read -ra) - a hand-added '10.*' token renders verbatim,
        # never pathname-expanded against CWD (mirrors f2b_whitelist_apply).
        read -ra toks <<<"${line#*=}"
        for tok in "${toks[@]+"${toks[@]}"}"; do
            if _f2b_wl_is_default "$tok"; then
                ui_log info "$tok  (default - locked)"
            else
                opts+=("Remove $tok")
                removable+=("$tok")
            fi
        done
        ((${#removable[@]} == 0)) && ui_log info "No user-added IPs yet."
        echo ""
        opts+=("Add an IP" "Back")
        local choice
        choice=$(ui_choose "Whitelist:" "${opts[@]}")
        case "$choice" in
            "Add an IP"*)
                f2b_whitelist_add "$jail_file"
                launcher_pause_for_menu
                ;;
            "Remove "*)
                f2b_whitelist_remove "${choice#Remove }" "$jail_file"
                launcher_pause_for_menu
                ;;
            *) return 0 ;;
        esac
    done
}

f2b_whitelist_add() {
    local jail_file="$1"
    echo ""
    # Quick-pick from currently-banned IPs (deduped by IP - one attacker is often
    # banned in several jails), plus the one opt-in manual path and Back.
    local opts=() ip
    while IFS= read -r ip; do [[ -n "$ip" ]] && opts+=("$ip"); done < <(_f2b_banned_pairs | cut -f2 | sort -u)
    opts+=("Type an IP address" "Back")
    local choice
    choice=$(ui_choose "Add which IP to the whitelist?" "${opts[@]}")
    case "$choice" in
        "Back"*) return 0 ;;
        "Type an IP address"*)
            # ui_input + explicit validate_ip, NEVER ui_input_validated: the required
            # loop can't be cleanly cancelled and death-loops on blank. Blank
            # Enter cancels; ui_input returns the empty default on non-TTY EOF too.
            ip=$(ui_input "IP address to always allow (blank to cancel)" "")
            [[ -z "$ip" ]] && {
                ui_log info "Cancelled - nothing changed."
                return 0
            }
            validate_ip "$ip" || return 0
            ;; # validator emits its own ui_log warn
        *) ip="$choice" ;;
    esac
    f2b_whitelist_apply add "$ip" "$jail_file"
}

f2b_whitelist_remove() {
    f2b_whitelist_apply remove "$1" "$2"
}

f2b_whitelist_apply() { # $1=add|remove  $2=ip  $3=jail-file path
    local op="$1" ip="$2" jail_file="$3" content line new_list new_content rc label toks tmp
    # Defensive: every caller feeds a validated, non-empty IP, but an empty $ip would
    # make grep -Fqw "" match anything (false dedup) and unban "" a no-op - guard once.
    [[ -z "$ip" ]] && {
        ui_log warn "No IP given - whitelist not changed."
        return 0
    }
    content=$(cat "$jail_file" 2>/dev/null)
    [[ -z "$content" ]] && content=$(sudo -n cat "$jail_file" 2>/dev/null)
    [[ -z "$content" ]] && {
        ui_log warn "Couldn't read $jail_file - whitelist not changed."
        return 0
    } # rule 1
    line=$(grep -m1 '^ignoreip[[:space:]]*=' <<<"$content")
    [[ -z "$line" ]] && {
        ui_log warn "No ignoreip line in $jail_file - whitelist not changed."
        return 0
    } # rule 3
    new_list=${line#*=}
    if [[ "$op" == add ]]; then
        # De-dup: -F literal, -w boundary (won't match inside a longer IP). Still
        # fire the best-effort unban before returning: ignoreip is enforced only at
        # ban time, so an IP already in the list can still be live-banned (a prior
        # add whose best-effort unban failed, or a hand-edit). f2b_ip_actions'
        # "Unban + always allow" relies on the add path unbanning, so the dedup
        # short-circuit must not drop it.
        if grep -Fqw "$ip" <<<"$line"; then
            docker exec fail2ban fail2ban-client unban "$ip" >/dev/null 2>&1 || true
            ui_log info "$ip is already whitelisted - cleared any active ban, nothing else changed."
            return 0
        fi
        new_list="$new_list $ip"
        label="Whitelist $ip"
    else # exact-token removal - no $ip-interpolated regex
        # Split glob-safe (read -ra, quoted expansion) BEFORE grep: the old unquoted
        # `printf '%s\n' $new_list` pathname-expanded a hand-added '10.*' token against
        # CWD, corrupting the line. The add path + the collapse below already guard this.
        read -ra toks <<<"$new_list"
        new_list=$(printf '%s\n' "${toks[@]+"${toks[@]}"}" | grep -vxF "$ip" | tr '\n' ' ')
        label="Remove $ip from whitelist"
    fi
    # Collapse/trim whitespace WITHOUT glob expansion (a hand-added '10.*' token must
    # survive verbatim, not expand to CWD filenames): read -ra word-splits with no
    # pathname expansion. toks=() first so an emptied line leaves ${toks[*]} safe under set -u.
    toks=()
    read -ra toks <<<"$new_list"
    new_list="${toks[*]}"
    ui_confirm "$label?" "no" || {
        ui_log info "Cancelled - nothing changed."
        return 0
    }
    # Rewrite ONLY the first ignoreip line, passing the new line VERBATIM via ENVIRON
    # (never awk -v, which processes backslash escapes) so no #/&/\/glob byte in the data
    # can corrupt or truncate. $new_content stays the WHOLE FILE (rule 2).
    new_content=$(NEW_LINE="ignoreip = $new_list" awk '
        !done && /^ignoreip[[:space:]]*=/ { print ENVIRON["NEW_LINE"]; done=1; next }
        { print }' <<<"$content")
    [[ -z "$new_content" ]] && {
        ui_log warn "Rebuilt whitelist came out empty - $jail_file not changed."
        return 0
    } # rule 4
    # Atomic write: build a sibling .tmp then mv over the live file, so a mid-write
    # ENOSPC/EIO can't half-truncate it. Every failure path removes the tmp and leaves
    # the live file untouched.
    tmp="$jail_file.tmp"
    if { printf '%s\n' "$new_content" >"$tmp" 2>/dev/null \
        || printf '%s\n' "$new_content" | sudo -n tee "$tmp" >/dev/null 2>&1; } \
        && { mv -f "$tmp" "$jail_file" 2>/dev/null || sudo -n mv -f "$tmp" "$jail_file" 2>/dev/null; }; then
        :
    else
        rm -f "$tmp" 2>/dev/null || sudo -n rm -f "$tmp" >/dev/null 2>&1 || true
        ui_log warn "Couldn't write $jail_file (permission denied) - whitelist not changed."
        return 0
    fi
    docker exec fail2ban fail2ban-client reload >/dev/null 2>&1
    rc=$?
    # Best-effort, add only: free the IP the moment it's whitelisted - reload alone
    # doesn't drop a live ban (ignoreip is enforced at ban time).
    [[ "$op" == add ]] && docker exec fail2ban fail2ban-client unban "$ip" >/dev/null 2>&1 || true
    if ((rc == 0)); then
        _show_action_result 0 "$label"
        [[ "$op" == add ]] && ui_log info "Note: a full rebuild (clean reinstall) resets the whitelist - re-add $ip if you ever do that."
    else
        # NOT _show_action_result 1 (its rc!=0 branch prints a false "exited with code 1"); the warn is accurate.
        ui_log warn "$label saved but fail2ban didn't reload - run 'docker compose restart fail2ban'."
    fi
    return 0 # explicit: remove's last branch is falsey; the function rc must not lie
}

f2b_do_unban() {
    local ip="$1" out rc
    out=$(docker exec fail2ban fail2ban-client unban "$ip" 2>&1)
    rc=$?
    # Live-verified against crazymax/fail2ban 1.1.0: `unban <ip>` always exits 0
    # and prints the count of jails the IP was cleared from - "0" means it wasn't
    # banned anywhere. The 'not banned' text match stays for other client versions.
    if [[ "$out" == "0" ]] || grep -qi 'not banned' <<<"$out"; then
        ui_log info "$ip wasn't banned in any jail - nothing to do."
    elif ((rc == 0)); then
        _show_action_result 0 "Unban $ip"
    else
        ui_log warn "Couldn't unban $ip: ${out:-fail2ban error}"
    fi
}

f2b_show_recent() {
    # ONE box per screen on BOTH paths: draw it unconditionally after clear, then
    # branch on whether the log had events (the old code returned before the box on
    # the empty path, leaving a boxless screen).
    clear
    ui_box "MediaStack - Recent ban history" "$(ui_kv 'Source' 'fail2ban log (last 20 Ban/Unban events)')"
    echo ""
    local lines
    lines=$(docker logs --tail 2000 fail2ban 2>&1 | grep -E '\] (Ban|Unban) ' | tail -20) || true
    if [[ -z "$lines" ]]; then
        ui_log info "No recent ban activity in the last ~2000 log lines. (Older events have rotated out - Docker keeps ~30 MB of fail2ban logs.)"
        return 0
    fi
    printf '%s\n' "$lines" | sed -E 's/[[:space:]]+fail2ban\.[^ ]+[[:space:]]+\[[0-9]+\]:[[:space:]]+[A-Z]+[[:space:]]+/  /'
}
