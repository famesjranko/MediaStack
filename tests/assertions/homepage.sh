assert_homepage_configured() {
    if svc_stripped homepage; then
        skip "step 8 Homepage: services.yaml + widgets" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    local services_yaml
    services_yaml=$(dind_exec "cat config/homepage/services.yaml 2>/dev/null")
    if [[ -n "$services_yaml" ]]; then
        pass "step 8 Homepage: services.yaml exists and is non-empty"
    else
        fail "step 8 Homepage: services.yaml exists and is non-empty"
        return
    fi

    for group in "Media:" "Media Management:" "Downloads:" "Admin:"; do
        if echo "$services_yaml" | grep -q "$group"; then
            pass "step 8 Homepage: group '$group' present"
        else
            fail "step 8 Homepage: group '$group' present" "not found in services.yaml"
        fi
    done

    # Network group is conditional — only present when proxy/remote services run
    local has_network_svc=false
    for svc in npm wireguard ddns-updater; do
        if ! svc_stripped "$svc"; then
            local svc_status
            svc_status=$(dind_exec "docker inspect --format '{{.State.Status}}' $svc 2>/dev/null" | tr -d '\r\n')
            if [[ "$svc_status" == "running" ]]; then
                has_network_svc=true
                break
            fi
        fi
    done
    if $has_network_svc; then
        if echo "$services_yaml" | grep -q "Network:"; then
            pass "step 8 Homepage: group 'Network:' present (network services running)"
        else
            fail "step 8 Homepage: group 'Network:' present" "network services running but group not found"
        fi
    else
        if echo "$services_yaml" | grep -q "Network:"; then
            fail "step 8 Homepage: group 'Network:' correctly omitted" "no network services but group found"
        else
            pass "step 8 Homepage: group 'Network:' correctly omitted (no network services)"
        fi
    fi

    if echo "$services_yaml" | grep -q "type: jellyfin"; then
        pass "step 8 Homepage: Jellyfin widget configured"
    else
        fail "step 8 Homepage: Jellyfin widget configured" "type: jellyfin not found"
    fi

    local missing_internal=()
    for internal_url in \
        "http://jellyfin:8096" \
        "http://sonarr:8989" \
        "http://radarr:7878" \
        "http://qbittorrent:8080" \
        "http://uptime-kuma:3001"; do
        echo "$services_yaml" | grep -q "$internal_url" || missing_internal+=("$internal_url")
    done
    if [[ ${#missing_internal[@]} -eq 0 ]]; then
        pass "step 8 Homepage: widgets use internal service URLs"
    else
        fail "step 8 Homepage: widgets use internal service URLs" "missing: ${missing_internal[*]}"
    fi

    local missing_conditional=() pair svc expected_url svc_status
    for pair in \
        "bazarr|http://bazarr:6767" \
        "npm|http://npm:81" \
        "wireguard|http://wireguard:51821" \
        "ddns-updater|http://ddns-updater:8000" \
        "beszel|http://beszel:8090"; do
        svc="${pair%%|*}"
        expected_url="${pair#*|}"
        svc_stripped "$svc" && continue
        svc_status=$(dind_exec "docker inspect --format '{{.State.Status}}' $svc 2>/dev/null" | tr -d '\r\n')
        [[ "$svc_status" == "running" ]] || continue
        echo "$services_yaml" | grep -q "$expected_url" || missing_conditional+=("$expected_url")
    done
    if [[ ${#missing_conditional[@]} -eq 0 ]]; then
        pass "step 8 Homepage: conditional services use internal URLs"
    else
        fail "step 8 Homepage: conditional services use internal URLs" "missing: ${missing_conditional[*]}"
    fi

    local remote_state
    remote_state=$(env_get REMOTE_WEB_STATE)
    if [[ "$remote_state" != "ready" ]]; then
        fail "step 8 Homepage: ready-state HTTPS assertions require REMOTE_WEB_STATE=ready" "DOMAIN=fresh.test REMOTE_WEB_STATE=${remote_state:-unset}"
    fi

    if echo "$services_yaml" | grep -q "jellyfin.fresh.test"; then
        pass "step 8 Homepage: ready-state HTTPS URLs used"
    else
        fail "step 8 Homepage: ready-state HTTPS URLs used" "expected jellyfin.fresh.test in href"
    fi

    # Verify default bookmarks were removed. Homepage truncates bookmarks.yaml on
    # every container start and only later (asynchronously) writes either defaults
    # or honours the seeded empty []; autoheal can restart Homepage during/after
    # configure.sh, re-truncating it mid-rewrite. A fixed short poll races both and
    # flakes under load — the file is observed empty (or mid-rewrite) before it
    # converges. Instead of "catch [] once within 10s", wait until the content has
    # CONVERGED AND is STABLE: [] seen on several consecutive reads. The bound is
    # generous because the rewrite legitimately lags under load, but the loop
    # breaks out the moment [] holds, so a healthy host still finishes in seconds.
    # Resetting the stability counter on any non-[] read also absorbs an autoheal
    # restart (which re-truncates) without a false pass.
    local bookmarks="" stable=0 _hp_i
    for ((_hp_i = 0; _hp_i < 45; _hp_i++)); do
        bookmarks=$(dind_exec "cat config/homepage/bookmarks.yaml 2>/dev/null" | tr -d '\r\n[:space:]')
        if [[ "$bookmarks" == "[]" ]]; then
            stable=$((stable + 1))
            ((stable >= 3)) && break
        else
            stable=0
        fi
        sleep 1
    done
    if ((stable >= 3)); then
        pass "step 8 Homepage: bookmarks.yaml converged to [] (no default links)"
    else
        fail "step 8 Homepage: bookmarks.yaml did not converge to []" "last value: ${bookmarks:-<empty>}"
    fi

    # Verify settings.yaml layout columns match service counts
    local layout_check
    layout_check=$(dind_exec "python3 -c \"
import yaml
with open('config/homepage/services.yaml') as f:
    services = yaml.safe_load(f) or []
with open('config/homepage/settings.yaml') as f:
    settings = yaml.safe_load(f) or {}
layout = settings.get('layout', {})
errors = []
for group_dict in services:
    for group_name, svc_list in group_dict.items():
        expected = min(len(svc_list), 4)
        actual = layout.get(group_name, {}).get('columns')
        if actual != expected:
            errors.append(f'{group_name}: expected {expected}, got {actual}')
# No layout entry should exist for groups not in services
svc_groups = set()
for gd in services:
    svc_groups.update(gd.keys())
for lg in layout:
    if lg not in svc_groups:
        errors.append(f'{lg}: in layout but not in services')
if errors:
    print('FAIL ' + '; '.join(errors))
else:
    print('OK')
\"" 2>/dev/null | tr -d '\r\n')
    if [[ "$layout_check" == "OK" ]]; then
        pass "step 8 Homepage: settings.yaml layout columns match service counts"
    else
        fail "step 8 Homepage: settings.yaml layout columns match service counts" "${layout_check#FAIL }"
    fi

    local http_code
    http_code=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000" 2>/dev/null | tr -d '\r\n')
    if [[ "$http_code" == "200" ]]; then
        pass "step 8 Homepage: accessible at port 3000 (HTTP 200)"
    else
        fail "step 8 Homepage: accessible at port 3000" "got HTTP $http_code"
    fi
}
