#!/bin/bash
# ============================================================================
#  Telegram message delivery
# ============================================================================

# Low-level send: tg_send <chat_id> <text> [parse_mode]
tg_send() {
    local chat_id="$1"
    local text="$2"
    local parse_mode="${3:-}"

    local response
    if [[ -n "$parse_mode" ]]; then
        response=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${chat_id}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "parse_mode=${parse_mode}")
    else
        response=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${chat_id}" \
            --data-urlencode "text=${text}")
    fi

    # Log if Telegram returned an error
    if [[ "$(echo "$response" | jq -r '.ok' 2>/dev/null)" != "true" ]]; then
        log_message "Telegram API error: $response"
    fi
}

# Alarm message to the alarm chat
send_alarm() {
    tg_send "$CHAT_ID_ALARM" "$1"
    log_message "ALARM -> $1"
}

# Informational HTML message to the info chat
send_info() {
    tg_send "$CHAT_ID_INFO" "$1" "HTML"
}
