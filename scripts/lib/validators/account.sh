# Owns: Admin account field validators (username, email, password).
# Sources: scripts/lib/validators.sh state; sourced by scripts/lib/validators.sh.

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
    if ((${#tld} < 2)); then
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
    if ((${#value} < 12)); then
        ui_log warn "Password must be at least 12 characters (Portainer requires this)."
        return 1
    fi
    # Uptime Kuma uses check-password-strength and rejects passwords with only
    # one character type as "Too weak". Require at least 2 of: lowercase,
    # uppercase, digits, symbols — so all-lowercase strings like qwertyuiopas
    # are caught here rather than failing silently at provision time.
    local types=0
    [[ "$value" =~ [a-z] ]] && ((types += 1)) || true
    [[ "$value" =~ [A-Z] ]] && ((types += 1)) || true
    [[ "$value" =~ [0-9] ]] && ((types += 1)) || true
    [[ "$value" =~ [^a-zA-Z0-9] ]] && ((types += 1)) || true
    if ((types < 2)); then
        ui_log warn "Password must use at least 2 character types (lowercase, uppercase, digits, symbols). Example: MyPass12 or pass123!"
        return 1
    fi
    return 0
}

