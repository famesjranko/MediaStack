# =============================================================================
# MediaStack UI library — public API
# =============================================================================
# Provides a unified interface for all user-facing output using pure bash
# (ANSI escape codes + unicode).
#
# Usage: source this file from setup.sh or configure.sh. All UI functions are
# prefixed with ui_ to avoid collisions with existing helpers.
#
# Demo mode: set UI_DEMO=1 to use simulated inputs and short delays.

# Resolve library directory relative to this file
UI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$UI_LIB_DIR/ui_fallback.sh"

# --- Public API ---

# Display the main application banner
# Usage: ui_banner "Title" "Subtitle"
ui_banner() {
    _ui_banner_impl "$@"
}

# Display a section header with step counter
# Usage: ui_section 3 9 "Configuring Sonarr"
ui_section() {
    _ui_section_impl "$@"
}

# Log a status message
# Usage: ui_log ok "Service configured"
#        ui_log warn "Config drift detected"
#        ui_log error "Connection failed"
#        ui_log info "Starting configuration..."
#        ui_log skip "Already configured"
ui_log() {
    _ui_log_impl "$@"
}

# Run a command with a spinner
# Usage: ui_spin "Waiting for Jellyfin..." command arg1 arg2
# Returns the command's exit code
ui_spin() {
    _ui_spin_impl "$@"
}

# Run a command with a spinner (command runs in foreground, preserving globals)
# Usage: ui_spin_fg "Detecting public IP..." net_detect_public_ip
# Use instead of ui_spin when the command sets global variables.
ui_spin_fg() {
    _ui_spin_fg_impl "$@"
}

# Prompt for text input
# Usage: result=$(ui_input "Prompt text" "default_value")
# In demo mode, returns default immediately
ui_input() {
    _ui_input_impl "$@"
}

# Prompt for text input with validator-driven re-prompt
# Usage: result=$(ui_input_validated "Prompt" "default" validate_fn [demo_default])
# - validate_fn is a function name; it's called with the entered value as $1 and
#   should return 0 on valid, non-zero on invalid. On invalid, the validator is
#   responsible for emitting its own ui_log warn before returning.
# - In DEMO=1 and UI_DEMO=1, returns demo_default (or default) without validation.
ui_input_validated() {
    _ui_input_validated_impl "$@"
}

# Prompt for password input (masked)
# Usage: result=$(ui_password "Prompt text" "default_value")
ui_password() {
    _ui_password_impl "$@"
}

# Prompt for yes/no confirmation
# Usage: ui_confirm "Enable Bazarr?" && echo "yes" || echo "no"
# Optional second arg: default (yes|no), defaults to "no"
ui_confirm() {
    _ui_confirm_impl "$@"
}

# Display a styled box with content
# Usage: ui_box "Title" "Line 1" "Line 2" ...
ui_box() {
    _ui_box_impl "$@"
}

# Display a key-value pair (for summaries)
# Usage: ui_kv "Service" "http://192.168.1.5:8096"
ui_kv() {
    _ui_kv_impl "$@"
}

# Display a horizontal divider
# Usage: ui_divider
#        ui_divider "Section Title"
ui_divider() {
    _ui_divider_impl "$@"
}

# Show a progress bar (pure display, not interactive)
# Usage: ui_progress 7 9 "Services configured"
ui_progress() {
    _ui_progress_impl "$@"
}

# In-place status line (overwrites current line)
# Usage: ui_status "Waiting... (30s) Still starting: sonarr radarr"
ui_status() {
    _ui_status_impl "$@"
}

# Clear the in-place status line
# Usage: ui_status_clear
ui_status_clear() {
    _ui_status_clear_impl
}

# Display a choice menu (select one from list)
# Usage: result=$(ui_choose "Select timezone:" "Etc/UTC" "America/New_York" "Europe/London")
ui_choose() {
    _ui_choose_impl "$@"
}
