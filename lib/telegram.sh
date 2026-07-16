#!/bin/bash
# ============================================================================
#  Telegram message delivery
# ============================================================================

# Escape text for parse_mode=HTML: html_escape <text>
# Node names come from config.sh and SFDP/version strings come from other
# people's APIs; a single "<" or "&" in either makes Telegram reject the whole
# message with a 400, and the dashboard silently never arrives.
#
# sed rather than ${s//&/&amp;}: since bash 5.2 an "&" in the replacement of a
# pattern substitution stands for the matched text, so "&lt;" would expand to
# "<lt;" — and older bash treats it literally, so the same code would behave
# differently per system. In sed, "\&" is an escaped literal everywhere.
# The ampersand rule must run first, or it would re-escape the entities below.
html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# One POST attempt. Prints the raw response body (empty if curl itself failed).
# _tg_post <chat_id> <text> <parse_mode>
_tg_post() {
    local args=(
        --silent
        --connect-timeout "${CONNECT_TIMEOUT:-5}"
        --max-time "${TG_TIMEOUT:-15}"
        -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
        --data-urlencode "chat_id=$1"
        --data-urlencode "text=$2"
    )
    [[ -n "$3" ]] && args+=(--data-urlencode "parse_mode=$3")
    curl "${args[@]}"
}

# Send with retries: tg_send <chat_id> <text> [parse_mode] [retries]
# Only transient failures are worth retrying (no response, 429, 5xx); a 4xx
# means the request itself is wrong and resending it changes nothing.
tg_send() {
    local chat_id="$1"
    local text="$2"
    local parse_mode="${3:-}"
    local retries="${4:-1}"

    if [[ "${TG_DRYRUN:-0}" == "1" ]]; then
        log_message "DRYRUN -> [${chat_id}] ${text}"
        return 0
    fi

    local attempt=1 delay="${ALARM_RETRY_DELAY:-2}"
    local response ok err retry_after
    while :; do
        response=$(_tg_post "$chat_id" "$text" "$parse_mode")
        ok=$(jq -r '.ok // empty' <<< "$response" 2>/dev/null)
        if [[ "$ok" == "true" ]]; then
            # Space the sends out: the hourly report fires one message per node
            # plus one per cluster back to back, and Telegram rate-limits a chat
            # at roughly 20/minute. Cheaper than handling the 429 afterwards.
            sleep "${TG_SEND_GAP:-0.4}"
            return 0
        fi

        err=$(jq -r '.error_code // empty' <<< "$response" 2>/dev/null)

        # Permanent client error — bad chat id, malformed HTML, bot kicked out.
        if [[ -n "$err" ]] && (( err >= 400 && err < 500 && err != 429 )); then
            log_message "Telegram API error (permanent): $response"
            return 1
        fi

        if (( attempt >= retries )); then
            log_message "Telegram API error (gave up after ${attempt}): ${response:-<no response>}"
            return 1
        fi

        # Telegram states how long to wait on 429 — obey it instead of guessing.
        retry_after=$(jq -r '.parameters.retry_after // empty' <<< "$response" 2>/dev/null)
        [[ -n "$retry_after" ]] && delay="$retry_after"

        log_message "Telegram send failed (attempt ${attempt}/${retries}), retry in ${delay}s: ${response:-<no response>}"
        sleep "$delay"
        delay=$(( delay * 2 ))
        (( attempt++ ))
    done
}

# Alarm message to the alarm chat. Retried: a dropped alarm is the exact
# failure this bot exists to prevent.
send_alarm() {
    tg_send "$CHAT_ID_ALARM" "$1" "" "${ALARM_RETRIES:-3}"
    log_message "ALARM -> $1"
}

# Informational HTML message to the info chat. Not retried — a missed hourly
# dashboard is not worth stalling the loop for.
send_info() {
    tg_send "$CHAT_ID_INFO" "$1" "HTML"
}
