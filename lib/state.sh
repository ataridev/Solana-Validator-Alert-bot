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
# Write to a temp file and rename, the way refresh_validators does. A plain
# truncate-then-write torn by a kill, a restart or a full disk leaves a 0-byte
# file, and alarm_step reads that as a brand-new problem: it re-fires an alarm
# that already went out, or — on a disk that stays full — never gets the count
# past the threshold, so the alarm never fires at all.
state_save() {
    local f; f="$(_state_file "$1" "$2")"
    printf '%s %s %s\n' "$3" "$4" "$5" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
}

# Remove state: state_clear <kind> <pubkey>
state_clear() {
    rm -f "$(_state_file "$1" "$2")" 2>/dev/null
}

# Whether an active state exists: state_active <kind> <pubkey>
state_active() {
    [[ -f "$(_state_file "$1" "$2")" ]]
}

# ============================================================================
#  Sticky-alarm state machine, shared by every problem kind.
# ============================================================================

# alarm_step <kind> <pubkey> <problem:0|1> <now_ts> [threshold] [repeat_interval]
# Sets ALARM_DECISION to one of:
#   none    — nothing to report
#   first   — problem confirmed <threshold> times in a row, alarm now
#   repeat  — still broken and <repeat_interval> has passed since the last one
#   recover — problem gone, and we had actually alarmed about it
# Leaves ST_START/ST_COUNT/ST_LAST loaded so the caller can build the message
# (duration, number of confirmations).
#
# threshold/repeat_interval default to ALERT_THRESHOLD/ALERT_REPEAT_INTERVAL,
# which suit a 10s watchdog. Slower checks pass their own: an hourly version
# check with a 5-minute repeat would re-alarm on every single check.
alarm_step() {
    local kind="$1" pubkey="$2" problem="$3" t="$4"
    local threshold="${5:-$ALERT_THRESHOLD}"
    local repeat="${6:-$ALERT_REPEAT_INTERVAL}"
    ALARM_DECISION="none"

    if (( problem )); then
        state_load "$kind" "$pubkey"
        if [[ -z "$ST_START" ]]; then
            ST_START="$t"; ST_COUNT=1; ST_LAST=0
        else
            ST_COUNT=$(( ST_COUNT + 1 ))
        fi

        if (( ST_LAST == 0 )); then
            # Not alarmed yet — fire once the problem is confirmed, so a single
            # bad poll cannot raise an alarm on its own.
            if (( ST_COUNT >= threshold )); then
                ST_LAST="$t"
                ALARM_DECISION="first"
            fi
        elif (( t - ST_LAST >= repeat )); then
            ST_LAST="$t"
            ALARM_DECISION="repeat"
        fi
        state_save "$kind" "$pubkey" "$ST_START" "$ST_COUNT" "$ST_LAST"
    else
        if state_active "$kind" "$pubkey"; then
            state_load "$kind" "$pubkey"
            state_clear "$kind" "$pubkey"
            if (( ST_LAST > 0 )); then
                ALARM_DECISION="recover"
            fi
        fi
    fi
}

# ============================================================================
#  Simple scalar marks (loop timers, daily flags).
#  On disk, so a restart does not replay the hourly summary or re-send a daily
#  message that already went out.
# ============================================================================

# mark_get <name> — prints the stored value, empty if never set
mark_get() {
    local f="$STATE_DIR/mark_$1"
    if [[ -f "$f" ]]; then
        head -1 "$f"
    fi
}

# mark_set <name> <value>
mark_set() {
    echo "$2" > "$STATE_DIR/mark_$1"
}
