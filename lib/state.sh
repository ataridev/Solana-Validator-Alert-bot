#!/bin/bash
# ============================================================================
#  Persistent delinquency/alarm state.
#  Stored in STATE_DIR/<kind>_<pubkey>.state files, so it survives a daemon
#  restart. File format: a single line "start_ts count last_alert_ts".
# ============================================================================

# Build a safe file name from the pubkey (just in case)
_state_file() {
    local kind="$1" pubkey="$2"
    echo "$STATE_DIR/${kind}_${pubkey}.state"
}

# Load state into globals ST_START ST_COUNT ST_LAST.
# state_load <kind> <pubkey>; if the file is missing, values are empty/0.
state_load() {
    local f; f="$(_state_file "$1" "$2")"
    ST_START=""; ST_COUNT=0; ST_LAST=0
    if [[ -f "$f" ]]; then
        read -r ST_START ST_COUNT ST_LAST < "$f"
        [[ -z "$ST_COUNT" ]] && ST_COUNT=0
        [[ -z "$ST_LAST" ]] && ST_LAST=0
    fi
}

# Save: state_save <kind> <pubkey> <start> <count> <last>
state_save() {
    echo "$3 $4 $5" > "$(_state_file "$1" "$2")"
}

# Remove state: state_clear <kind> <pubkey>
state_clear() {
    rm -f "$(_state_file "$1" "$2")" 2>/dev/null
}

# Whether an active state exists: state_active <kind> <pubkey>
state_active() {
    [[ -f "$(_state_file "$1" "$2")" ]]
}
