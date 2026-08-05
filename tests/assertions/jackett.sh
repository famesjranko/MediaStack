assert_jackett_configured() {
    local jackett_key
    jackett_key=$(api_get_jackett_key)
    if [[ -n "$jackett_key" && ${#jackett_key} -ge 20 ]]; then
        pass "step 2 Jackett: API key present (${jackett_key:0:8}…)"
    else
        fail "step 2 Jackett: API key present" "got='${jackett_key}'"
    fi

    local indexers_raw
    indexers_raw=$(dind_exec "python3 -c \"import yaml; c=yaml.safe_load(open('config.yml')); print(' '.join(i['id'] for i in (c.get('indexers') or [])))\"" 2>/dev/null)
    local indexers=()
    if [[ -n "$indexers_raw" ]]; then
        read -r -a indexers <<<"$indexers_raw"
    fi
    if ((${#indexers[@]} == 0)); then
        skip "step 2 Jackett: indexer caps checks" "no indexers configured"
        return 0
    fi

    local caps_ok=0 caps_fail=0 caps_fail_names=""
    for idx in "${indexers[@]}"; do
        local caps_resp
        caps_resp=$(dind_exec "curl -sf --max-time 15 'http://localhost:9117/api/v2.0/indexers/${idx}/results/torznab/?apikey=${jackett_key}&t=caps'" 2>/dev/null)
        if echo "$caps_resp" | grep -q '<caps>'; then
            ((caps_ok++))
        else
            ((caps_fail++))
            caps_fail_names="${caps_fail_names:+$caps_fail_names, }$idx"
        fi
    done
    if [[ "$caps_fail" -eq 0 ]]; then
        pass "step 2 Jackett: all ${caps_ok} indexers serving Torznab caps"
    else
        fail "step 2 Jackett: all indexers serving Torznab caps" \
            "${caps_ok} ok, ${caps_fail} failed: ${caps_fail_names}"
    fi
}
