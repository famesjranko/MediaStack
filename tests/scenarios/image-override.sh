# tests/scenarios/image-override.sh — proves the candidate-image preflight
# override mechanism actually patches the DinD compose copy.
#
# Supply the override EXTERNALLY on the runner invocation. run.sh applies
# MS_TEST_IMAGE_OVERRIDES (via dind_override_images) BEFORE any scenario runs,
# so this scenario must NOT set it itself — it only verifies the result:
#
#   MS_TEST_IMAGE_OVERRIDES="wireguard=example.invalid/wg:0" ./tests/run.sh --no-preload image-override
#
# Cheap: renders `docker compose config` only — no image pull, no `up`. Fails
# when no override was supplied, so it can never silently pass (a same-tag
# override would not prove the patch happened either).

run_scenario() {
    if [[ -z "${MS_TEST_IMAGE_OVERRIDES:-}" ]]; then
        fail "image-override requires MS_TEST_IMAGE_OVERRIDES" \
            'e.g. MS_TEST_IMAGE_OVERRIDES="wireguard=example.invalid/wg:0" ./tests/run.sh image-override'
        return 1
    fi

    # .env so `docker compose config` resolves variable interpolation cleanly.
    dind_exec "cp .env.example .env"

    # Render the fully-profiled compose (the DinD copy run.sh already patched).
    local config_json
    config_json=$(dind_exec "docker compose --profile remote --profile proxy --profile subtitles --profile autoheal config --format json 2>/dev/null")
    if [[ -z "$config_json" ]]; then
        fail "docker compose config rendered"
        dind_exec "docker compose --profile remote --profile proxy --profile subtitles --profile autoheal config 2>&1 | tail -20"
        return 1
    fi
    pass "docker compose config rendered"

    # For each svc=ref override, assert the rendered image matches — proving the
    # patch reached compose. Parse host-side (stdlib json only).
    local pair svc ref got
    for pair in $(echo "$MS_TEST_IMAGE_OVERRIDES" | tr ',' ' '); do
        svc="${pair%%=*}"
        ref="${pair#*=}"
        got=$(printf '%s' "$config_json" | SVC="$svc" python3 -c \
            'import json,os,sys; print((json.load(sys.stdin)["services"].get(os.environ["SVC"]) or {}).get("image",""))' \
            2>/dev/null)
        assert_eq "$ref" "$got" "override applied to compose: $svc"
    done

    # A same-tag override proves nothing — the rendered image would equal the pin
    # regardless. dind_override_images records old->new; fail any vacuous one.
    local rec rsvc rold rnew
    rec=$(dind_exec "cat tests/.image-override-applied 2>/dev/null")
    if [[ -z "$rec" ]]; then
        fail "image-override applied record present"
    else
        while IFS=$'\t' read -r rsvc rold rnew; do
            [[ -z "$rsvc" ]] && continue
            if [[ "$rold" == "$rnew" ]]; then
                fail "override changes the image: $rsvc" "vacuous same-image override ($rold)"
            else
                pass "override changes the image: $rsvc ($rold -> $rnew)"
            fi
        done <<< "$rec"
    fi
}
