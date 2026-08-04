# Owns: optional SMB share behavior tests.
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/samba.sh.

# setup_samba — point the file paths at writable tmpfs locations so the tests
# can drive the cleanup/idempotency branches that depend on file existence.
# ===========================================================================
SAMBA_TMP=$(mktemp -d)
SAMBA_INCLUDE_FILE="$SAMBA_TMP/mediastack.conf"
SAMBA_MAIN_CONF="$SAMBA_TMP/smb.conf"

# ===========================================================================
# setup_samba — SMB_ENABLED=false, no prior install (immediate return)
# ===========================================================================

SAMBA_CALLS=()
sudo() {
    SAMBA_CALLS+=("$*")
    return 0
}
systemctl() {
    SAMBA_CALLS+=("systemctl $*")
    return 0
}

rm -f "$SAMBA_INCLUDE_FILE"
SMB_ENABLED="false"
SAMBA_CALLS=()
setup_samba
assert_eq "0" "${#SAMBA_CALLS[@]}" "setup_samba: SMB_ENABLED=false + no include file — no action"
unset -f sudo systemctl

# ===========================================================================
# setup_samba — SMB_ENABLED=false WITH a prior install present (cleanup path)
# Bug we're guarding against: the early-return historically left orphaned
# MediaStack stanzas in /etc/samba/smb.conf on reinstall with SMB=no. New
# behavior: rm the include file. The dangling `include = …` line in main
# smb.conf is intentionally left in place — samba tolerates a missing include
# with just a warning, and a future SMB_ENABLED=true install reuses the path.
# ===========================================================================

mkdir -p "$(dirname "$SAMBA_INCLUDE_FILE")"
cat >"$SAMBA_INCLUDE_FILE" <<'EOF'
[Media]
   path = /
EOF
cat >"$SAMBA_MAIN_CONF" <<EOF
[global]
   workgroup = WORKGROUP
   security = user

# Pre-existing user share — must NOT be touched by cleanup
[UserShare]
   path = /home/user/share
   read only = no

# MEDIASTACK include — managed by setup.sh
include = $SAMBA_INCLUDE_FILE
EOF

sudo() {
    case "${1:-}" in
        rm)
            shift
            command rm "$@"
            return 0
            ;;
        systemctl) return 0 ;;
        *) return 0 ;;
    esac
}

SMB_ENABLED="false"
setup_samba

[[ ! -f "$SAMBA_INCLUDE_FILE" ]] \
    && pass "setup_samba: cleanup removes mediastack.conf include file" \
    || fail "setup_samba: cleanup removes mediastack.conf include file" "still present"

if grep -Fq '[UserShare]' "$SAMBA_MAIN_CONF" \
    && grep -Fq 'path = /home/user/share' "$SAMBA_MAIN_CONF"; then
    pass "setup_samba: cleanup preserves pre-existing user [UserShare] section"
else
    fail "setup_samba: cleanup preserves pre-existing user [UserShare] section" \
        "lost user content:\n$(cat "$SAMBA_MAIN_CONF")"
fi

unset -f sudo

# ===========================================================================
# setup_samba — skip path (include file present + include line in main conf)
# Idempotency: re-running on an already-configured host must do no work.
# ===========================================================================

mkdir -p "$(dirname "$SAMBA_INCLUDE_FILE")"
cat >"$SAMBA_INCLUDE_FILE" <<'EOF'
[Media]
   path = /data
EOF
cat >"$SAMBA_MAIN_CONF" <<EOF
[global]
   workgroup = WORKGROUP

# MEDIASTACK include — managed by setup.sh
include = $SAMBA_INCLUDE_FILE
EOF

SAMBA_CALLS=()
sudo() {
    if [[ "${1:-}" == "grep" ]]; then
        shift
        command grep "$@"
        return $?
    fi
    SAMBA_CALLS+=("$*")
    return 0
}
# Stub smbd so `command -v smbd` short-circuits the install-samba branch
# that otherwise pollutes SAMBA_CALLS with an apt-get call on hosts where
# samba isn't installed. See note in the fresh-path test.
smbd() { :; }

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SMB_ENABLED="true"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
JELLYFIN_ADMIN_USER="testadmin"
JELLYFIN_ADMIN_PASSWORD="testpass"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
DATA_DIR="/data"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
PGID="1000"
setup_samba
# Skip path runs ONLY the grep idempotency check, then returns. No useradd,
# no tee, no systemctl, no ufw — which means SAMBA_CALLS stays empty.
assert_eq "0" "${#SAMBA_CALLS[@]}" "setup_samba: skip when include file + include line both present"
unset -f sudo smbd

# Regression: idempotency keys on the functional `include = <path>` line, NOT a
# decorative comment marker. An existing install whose main smb.conf has the
# include line but no (or a differently-punctuated) comment must still be
# detected as already-configured — a prose marker's em-dash was once a fragile
# byte-exact grep target that silently broke this.
cat >"$SAMBA_MAIN_CONF" <<EOF
[global]
   workgroup = WORKGROUP

include = $SAMBA_INCLUDE_FILE
EOF
SAMBA_CALLS=()
sudo() {
    if [[ "${1:-}" == "grep" ]]; then
        shift
        command grep "$@"
        return $?
    fi
    SAMBA_CALLS+=("$*")
    return 0
}
smbd() { :; }
SMB_ENABLED="true"
JELLYFIN_ADMIN_USER="testadmin"
JELLYFIN_ADMIN_PASSWORD="testpass"
DATA_DIR="/data"
PGID="1000"
setup_samba
assert_eq "0" "${#SAMBA_CALLS[@]}" "setup_samba: skip is comment-independent (detects bare include line, no marker)"
unset -f sudo smbd

# A matching include from an interrupted run must resume the remaining
# idempotent work instead of taking the completed-install fast path forever.
PENDING_HASH=$(sha256sum "$SAMBA_INCLUDE_FILE" | awk '{print $1}')
PENDING_CALLS=()
PENDING_STATE=()
_ms_state_get() {
    case "$1" in
        SAMBA_SETUP_PENDING | SAMBA_OWNERSHIP_RECORDED | SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK) echo true ;;
        SAMBA_USER) echo testadmin ;;
        SAMBA_PASSDB_PREEXISTED | SAMBA_GROUP_PREEXISTED) echo false ;;
        SAMBA_GROUP) echo media ;;
        SAMBA_INCLUDE_SHA256) echo "$PENDING_HASH" ;;
    esac
}
_ms_state_set() { PENDING_STATE+=("$1=$2"); }
sudo() {
    case "${1:-}" in
        grep | install | tee | sha256sum) command "$@" ;;
        pdbedit) return 0 ;;
        testparm) echo effective ;;
        systemctl | ufw)
            PENDING_CALLS+=("$*")
            return 0
            ;;
        *) return 0 ;;
    esac
}
smbd() { :; }
id() {
    [[ "${1:-}" == -nG ]] && echo media
    return 0
}
getent() { echo 'media:x:1000:'; }
SMB_ENABLED=true
JELLYFIN_ADMIN_USER=testadmin
JELLYFIN_ADMIN_PASSWORD=testpass
DATA_DIR=/data
PGID=1000
setup_samba
assert_contains "${PENDING_CALLS[*]}" "systemctl enable --now smbd" \
    "setup_samba: interrupted matching config resumes remaining work"
assert_contains "${PENDING_STATE[*]}" "SAMBA_SETUP_PENDING=false" \
    "setup_samba: successful resume clears the pending ledger state"
unset -f sudo smbd id getent
_ms_state_get() { echo false; }
_ms_state_set() { :; }

# ===========================================================================
# setup_samba — fresh path: writes include file (NOT main smb.conf) + appends
# the include line to main conf without overwriting it.
# Bug we're guarding against: the prior implementation `sudo tee smb.conf`
# (no -a) overwrote the entire file, destroying any pre-existing user samba
# config. New behavior must write to the include file and append-only.
# ===========================================================================

# Seed main smb.conf with pre-existing user content that must survive.
rm -f "$SAMBA_INCLUDE_FILE"
cat >"$SAMBA_MAIN_CONF" <<'EOF'
[global]
   workgroup = HOMEUSER
   security = user

[UserShare]
   path = /home/user/share
   read only = no
EOF
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SAMBA_MAIN_BEFORE_BYTES=$(wc -c <"$SAMBA_MAIN_CONF")

SAMBA_CALLS=()
sudo() {
    case "${1:-}" in
        grep)
            shift
            command grep "$@"
            return $?
            ;;
        useradd)
            SAMBA_CALLS+=("useradd")
            return 0
            ;;
        usermod)
            SAMBA_CALLS+=("usermod")
            return 0
            ;;
        install)
            shift
            command install "$@"
            return 0
            ;;
        # `sudo tee` here also runs from inside the right side of a pipe
        # (`printf … | sudo tee -a $main`). Pipe RHS executes in a subshell,
        # so any `SAMBA_CALLS+=(…)` we'd add inside the function would be
        # invisible to the parent. We rely on the file-content assertions
        # below to verify the include-line append, instead of capturing the
        # call into the array.
        tee)
            shift
            command tee "$@" >/dev/null
            return 0
            ;;
        smbpasswd)
            shift
            smbpasswd "$@"
            return $?
            ;;
        pdbedit) return 1 ;;
        systemctl)
            SAMBA_CALLS+=("systemctl $2")
            return 0
            ;;
        ufw)
            SAMBA_CALLS+=("ufw $*")
            return 0
            ;;
        *) return 0 ;;
    esac
}
# `command -v smbd` is consulted before the install path; on hosts without
# samba installed (e.g. the dev box running this test) it returns 1 and
# triggers a `sudo apt-get install`. Stubbing smbd as a function makes
# `command -v smbd` succeed (functions are visible to `command -v`) so the
# install-path check stays a no-op and doesn't pollute SAMBA_CALLS.
smbd() { :; }
smbpasswd() {
    SAMBA_CALLS+=("smbpasswd")
    return 0
}
id() {
    if [[ "${1:-}" == "-u" || "${1:-}" == "-g" ]]; then
        echo "1000"
        return 0
    fi
    return 1
}
getent() {
    if [[ "${1:-}" == "group" ]]; then
        echo "mediaadmin:x:1000:"
        return 0
    fi
    return 1
}

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SMB_ENABLED="true"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
JELLYFIN_ADMIN_USER="testadmin"
JELLYFIN_ADMIN_PASSWORD="testpass"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
DATA_DIR="/data"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
PGID="1000"

SAMBA_CALLS=()
setup_samba

# Ergonomic checks via captured calls — these all happen in the function's
# own process so SAMBA_CALLS sees them. The two tee invocations are NOT
# captured (one runs via heredoc, one runs in a pipe subshell — neither
# can write back to the parent's array). File-content assertions below
# cover the actual write behavior.
found_useradd=false
found_systemctl=false
found_ufw=false
for c in "${SAMBA_CALLS[@]}"; do
    [[ "$c" == "useradd" ]] && found_useradd=true
    [[ "$c" == *"systemctl enable"* ]] && found_systemctl=true
    [[ "$c" == *"ufw"*"445"* ]] && found_ufw=true
done
assert_eq "true" "$found_useradd" "setup_samba: fresh — creates system user"
assert_eq "true" "$found_systemctl" "setup_samba: fresh — enables smbd"
assert_eq "true" "$found_ufw" "setup_samba: fresh — adds UFW rules for port 445"

# Belt-and-braces: explicitly verify the user's pre-existing content survived.
if grep -Fq '[UserShare]' "$SAMBA_MAIN_CONF" \
    && grep -Fq 'path = /home/user/share' "$SAMBA_MAIN_CONF" \
    && grep -Fq 'workgroup = HOMEUSER' "$SAMBA_MAIN_CONF"; then
    pass "setup_samba: fresh — user's pre-existing smb.conf content survived"
else
    fail "setup_samba: fresh — user's pre-existing smb.conf content survived" \
        "main conf after install:\n$(cat "$SAMBA_MAIN_CONF")"
fi

# And the include line was actually appended.
if grep -Fxq "include = $SAMBA_INCLUDE_FILE" "$SAMBA_MAIN_CONF"; then
    pass "setup_samba: fresh — include line present in main smb.conf"
else
    fail "setup_samba: fresh — include line present in main smb.conf" \
        "no match in:\n$(cat "$SAMBA_MAIN_CONF")"
fi

if grep -Fxq "   path = /data" "$SAMBA_INCLUDE_FILE"; then
    pass "setup_samba: fresh — default SMB scope shares DATA_DIR"
else
    fail "setup_samba: fresh — default SMB scope shares DATA_DIR" \
        "include file:\n$(cat "$SAMBA_INCLUDE_FILE")"
fi

# Backslash escapes in the shared admin password must pass through to
# smbpasswd literally. `smbpasswd -s` reads two newline-delimited password
# entries from stdin; interpreting `\n`, `\t`, `\c`, or `\\` changes the
# password before Samba receives it.
rm -f "$SAMBA_INCLUDE_FILE"
cat >"$SAMBA_MAIN_CONF" <<'EOF'
[global]
   workgroup = HOMEUSER
EOF
SMB_SHARE_SCOPE="data"
JELLYFIN_ADMIN_PASSWORD='alpha\nbravo\tcharlie\cdelta\\end'
SMB_PASS_STDIN="$SAMBA_TMP/smbpasswd.stdin"
SMB_PASS_EXPECTED="$SAMBA_TMP/smbpasswd.expected"
smbpasswd() {
    cat >"$SMB_PASS_STDIN"
    return 0
}

setup_samba
printf '%s\n%s\n' "$JELLYFIN_ADMIN_PASSWORD" "$JELLYFIN_ADMIN_PASSWORD" >"$SMB_PASS_EXPECTED"
if cmp -s "$SMB_PASS_EXPECTED" "$SMB_PASS_STDIN"; then
    pass "setup_samba: fresh — smbpasswd receives passwords with backslashes literally"
else
    fail "setup_samba: fresh — smbpasswd receives passwords with backslashes literally" \
        "expected:\n$(od -An -tx1 -c "$SMB_PASS_EXPECTED")\nactual:\n$(od -An -tx1 -c "$SMB_PASS_STDIN")"
fi
unset SMB_SHARE_SCOPE

rm -f "$SAMBA_INCLUDE_FILE"
cat >"$SAMBA_MAIN_CONF" <<'EOF'
[global]
   workgroup = HOMEUSER
EOF
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SMB_SHARE_SCOPE="system"
setup_samba
if grep -Fxq "[MediaStackSystem]" "$SAMBA_INCLUDE_FILE" \
    && grep -Fxq "   path = /" "$SAMBA_INCLUDE_FILE"; then
    pass "setup_samba: system SMB scope keeps full filesystem access explicit"
else
    fail "setup_samba: system SMB scope keeps full filesystem access explicit" \
        "include file:\n$(cat "$SAMBA_INCLUDE_FILE")"
fi
unset SMB_SHARE_SCOPE

unset -f sudo smbpasswd id getent
rm -rf "$SAMBA_TMP"

