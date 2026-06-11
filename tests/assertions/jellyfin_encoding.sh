assert_jellyfin_encoding() {
    # 5b. Intel QSV encoding
    env_set JELLYFIN_GPU intel
    local encoding_log=/tmp/configure-encoding.out
    if dind_exec "UI_ASCII=1 ./scripts/configure.sh --only jellyfin" >"$encoding_log" 2>&1; then
        local encoding_log_stripped
        encoding_log_stripped=$(sed -r 's/\x1b\[[0-9;]*m//g' "$encoding_log")

        if echo "$encoding_log_stripped" | grep -q '\[OK\].*Hardware transcoding: qsv'; then
            pass "step 5b Jellyfin: encoding auto-configured to qsv"
        else
            fail "step 5b Jellyfin: encoding auto-configured to qsv" \
                "$(echo "$encoding_log_stripped" | grep -i 'transcod\|encod\|hardware' | head -3)"
        fi

        if [[ -n "${JF_TOKEN:-}" ]]; then
            local jf_encoding_after
            jf_encoding_after=$(dind_exec "curl -sf -H 'Authorization: $JF_AUTH_HEADER, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration/encoding")
            local jf_accel_after
            jf_accel_after=$(echo "$jf_encoding_after" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("HardwareAccelerationType",""))' 2>/dev/null | tr -d '\r\n')
            assert_eq "qsv" "$jf_accel_after" "step 5b Jellyfin: API confirms qsv"
        fi

        # Idempotency: re-run should skip, not re-apply
        local encoding_rerun_log=/tmp/configure-encoding-rerun.out
        dind_exec "UI_ASCII=1 ./scripts/configure.sh --only jellyfin" >"$encoding_rerun_log" 2>&1
        local rerun_stripped
        rerun_stripped=$(sed -r 's/\x1b\[[0-9;]*m//g' "$encoding_rerun_log")
        if echo "$rerun_stripped" | grep -q '\[SKIP\].*Hardware transcoding already set to qsv'; then
            pass "step 5b Jellyfin: encoding idempotent (skipped on re-run)"
        else
            fail "step 5b Jellyfin: encoding idempotent (skipped on re-run)" \
                "$(echo "$rerun_stripped" | grep -i 'transcod\|encod\|hardware' | head -3)"
        fi

        if echo "$rerun_stripped" | grep -q '\[SKIP\].*Jellyfin networking already configured'; then
            pass "step 5 Jellyfin: networking idempotent (skipped on re-run)"
        else
            fail "step 5 Jellyfin: networking idempotent (skipped on re-run)" \
                "$(echo "$rerun_stripped" | grep -i 'network' | head -3)"
        fi
    else
        fail "step 5b Jellyfin: configure.sh exits 0 with JELLYFIN_GPU=intel"
    fi

    # 5b2. AMD VAAPI encoding path
    if [[ -n "${JF_TOKEN:-}" ]]; then
        local jf_auth="$JF_AUTH_HEADER"
        local amd_reset_body
        amd_reset_body=$(dind_exec "curl -sf -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration/encoding" \
            | python3 -c 'import sys,json; c=json.load(sys.stdin); c["HardwareAccelerationType"]="none"; print(json.dumps(c))')
        dind_exec "curl -sf -X POST \
            -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' \
            -H 'Content-Type: application/json' \
            -d '$amd_reset_body' \
            http://localhost:8096/System/Configuration/encoding" >/dev/null

        env_set JELLYFIN_GPU amd
        local amd_log=/tmp/configure-amd-vaapi.out
        dind_exec "UI_ASCII=1 ./scripts/configure.sh --only jellyfin" >"$amd_log" 2>&1
        local amd_stripped
        amd_stripped=$(sed -r 's/\x1b\[[0-9;]*m//g' "$amd_log")

        if echo "$amd_stripped" | grep -q '\[OK\].*Hardware transcoding: vaapi'; then
            pass "step 5b2 Jellyfin: AMD encoding auto-configured to vaapi"
        else
            fail "step 5b2 Jellyfin: AMD encoding auto-configured to vaapi" \
                "$(echo "$amd_stripped" | grep -i 'transcod\|encod\|hardware' | head -3)"
        fi

        local amd_encoding
        amd_encoding=$(dind_exec "curl -sf -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration/encoding")
        local amd_accel
        amd_accel=$(echo "$amd_encoding" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("HardwareAccelerationType",""))' 2>/dev/null | tr -d '\r\n')
        assert_eq "vaapi" "$amd_accel" "step 5b2 Jellyfin: API confirms AMD vaapi"

        local amd_vaapi_device
        amd_vaapi_device=$(echo "$amd_encoding" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("VaapiDevice",""))' 2>/dev/null | tr -d '\r\n')
        assert_eq "/dev/dri/renderD128" "$amd_vaapi_device" "step 5b2 Jellyfin: AMD VaapiDevice set"

        local amd_vpp_tonemap
        amd_vpp_tonemap=$(echo "$amd_encoding" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("EnableVppTonemapping",False))' 2>/dev/null | tr -d '\r\n')
        assert_eq "False" "$amd_vpp_tonemap" "step 5b2 Jellyfin: AMD does not enable Intel VPP tonemapping"

        local amd_tonemap
        amd_tonemap=$(echo "$amd_encoding" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("EnableTonemapping",False))' 2>/dev/null | tr -d '\r\n')
        assert_eq "True" "$amd_tonemap" "step 5b2 Jellyfin: AMD tonemapping enabled"
    fi

    # 5c. NVENC encoding path
    if [[ -n "${JF_TOKEN:-}" ]]; then
        local jf_auth="$JF_AUTH_HEADER"
        local reset_body
        reset_body=$(dind_exec "curl -sf -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration/encoding" \
            | python3 -c 'import sys,json; c=json.load(sys.stdin); c["HardwareAccelerationType"]="none"; print(json.dumps(c))')
        dind_exec "curl -sf -X POST \
            -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' \
            -H 'Content-Type: application/json' \
            -d '$reset_body' \
            http://localhost:8096/System/Configuration/encoding" >/dev/null

        env_set JELLYFIN_GPU nvidia
        local nvenc_log=/tmp/configure-nvenc.out
        dind_exec "UI_ASCII=1 ./scripts/configure.sh --only jellyfin" >"$nvenc_log" 2>&1
        local nvenc_stripped
        nvenc_stripped=$(sed -r 's/\x1b\[[0-9;]*m//g' "$nvenc_log")

        if echo "$nvenc_stripped" | grep -q '\[OK\].*Hardware transcoding: nvenc'; then
            pass "step 5c Jellyfin: encoding auto-configured to nvenc"
        else
            fail "step 5c Jellyfin: encoding auto-configured to nvenc" \
                "$(echo "$nvenc_stripped" | grep -i 'transcod\|encod\|hardware' | head -3)"
        fi

        local nvenc_encoding
        nvenc_encoding=$(dind_exec "curl -sf -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration/encoding")
        local nvenc_accel
        nvenc_accel=$(echo "$nvenc_encoding" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("HardwareAccelerationType",""))' 2>/dev/null | tr -d '\r\n')
        assert_eq "nvenc" "$nvenc_accel" "step 5c Jellyfin: API confirms nvenc"

        local nvenc_enhanced
        nvenc_enhanced=$(echo "$nvenc_encoding" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("EnableEnhancedNvdecDecoder",False))' 2>/dev/null | tr -d '\r\n')
        assert_eq "True" "$nvenc_enhanced" "step 5c Jellyfin: EnableEnhancedNvdecDecoder set"

        local nvenc_tonemap
        nvenc_tonemap=$(echo "$nvenc_encoding" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("EnableTonemapping",False))' 2>/dev/null | tr -d '\r\n')
        assert_eq "True" "$nvenc_tonemap" "step 5c Jellyfin: EnableTonemapping set"
    fi

    # 5d. Encoding drift
    if [[ -n "${JF_TOKEN:-}" ]]; then
        local jf_auth="$JF_AUTH_HEADER"
        local drift_reset_body
        drift_reset_body=$(dind_exec "curl -sf -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration/encoding" \
            | python3 -c 'import sys,json; c=json.load(sys.stdin); c["HardwareAccelerationType"]="none"; print(json.dumps(c))')
        dind_exec "curl -sf -X POST \
            -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' \
            -H 'Content-Type: application/json' \
            -d '$drift_reset_body' \
            http://localhost:8096/System/Configuration/encoding" >/dev/null

        env_set JELLYFIN_GPU intel
        dind_exec "UI_ASCII=1 ./scripts/configure.sh --only jellyfin" >/dev/null 2>&1

        local drift_encoding_body
        drift_encoding_body=$(dind_exec "curl -sf -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration/encoding" \
            | python3 -c 'import sys,json; c=json.load(sys.stdin); c["HardwareAccelerationType"]="nvenc"; print(json.dumps(c))')
        dind_exec "curl -sf -X POST \
            -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' \
            -H 'Content-Type: application/json' \
            -d '$drift_encoding_body' \
            http://localhost:8096/System/Configuration/encoding" >/dev/null

        local drift_encoding_log=/tmp/configure-encoding-drift.out
        dind_exec "UI_ASCII=1 ./scripts/configure.sh --only jellyfin" >"$drift_encoding_log" 2>&1
        local drift_encoding_stripped
        drift_encoding_stripped=$(sed -r 's/\x1b\[[0-9;]*m//g' "$drift_encoding_log")
        if echo "$drift_encoding_stripped" | grep -q "\[WARN\].*Jellyfin transcoding is 'nvenc', expected 'qsv'"; then
            pass "step 5d Jellyfin: encoding drift detected (nvenc != qsv)"
        else
            fail "step 5d Jellyfin: encoding drift detected" \
                "$(echo "$drift_encoding_stripped" | grep -i 'transcod\|encod\|hardware' | head -3)"
        fi

        local restore_encoding_body
        restore_encoding_body=$(dind_exec "curl -sf -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration/encoding" \
            | python3 -c 'import sys,json; c=json.load(sys.stdin); c["HardwareAccelerationType"]="qsv"; print(json.dumps(c))')
        dind_exec "curl -sf -X POST \
            -H 'Authorization: $jf_auth, Token=\"$JF_TOKEN\"' \
            -H 'Content-Type: application/json' \
            -d '$restore_encoding_body' \
            http://localhost:8096/System/Configuration/encoding" >/dev/null
    fi

    env_set JELLYFIN_GPU none
}
