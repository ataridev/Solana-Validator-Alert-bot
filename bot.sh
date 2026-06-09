#!/bin/bash
# ============================================================================
#  Solana Validator Bot — unified Solana validator monitoring.
#
#  Features:
#   • fast delinquency watchdog with confirmation/anti-spam/recovery;
#   • rich dashboard: balance, stake, skip, credits, rank, commission;
#   • efficiency: one validators request per cluster per cycle, not per node;
#   • persistent state that survives a daemon restart.
#
#  Run: ./bot.sh   (usually under systemd, see solana-validator-alert-bot.service)
# ============================================================================
set -uo pipefail
export LC_NUMERIC="en_US.UTF-8"

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Logging (needed before the libraries are sourced) ----------------------
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z') - $1" | tee -a "$LOG_FILE" 2>/dev/null
}

# --- Config, secrets, libraries --------------------------------------------
source "$BOT_DIR/config.sh"

if [[ ! -f "$BOT_DIR/secrets.env" ]]; then
    echo "ERROR: secrets.env is missing. Copy secrets.env.example and fill it in." >&2
    exit 1
fi
source "$BOT_DIR/secrets.env"

mkdir -p "$STATE_DIR"
source "$BOT_DIR/lib/telegram.sh"
source "$BOT_DIR/lib/solana.sh"
source "$BOT_DIR/lib/state.sh"

now() { date +%s; }

# ============================================================================
#  CHECKS (fast)
# ============================================================================

# Delinquency watchdog.
# State fields (kind=delinq): ST_START=first seen, ST_COUNT=consecutive hits,
# ST_LAST=last alarm ts (0 = not alarmed yet).
#  • First alarm only after ALERT_THRESHOLD consecutive confirmations
#    (avoids false positives from a single bad poll).
#  • Then repeats every ALERT_REPEAT_INTERVAL.
#  • Recovery message only if we had actually alarmed.
check_delinquency() {
    local pubkey="$1" name="$2" cluster="$3"
    local status; status=$(validator_field "$cluster" "$pubkey" ".delinquent")
    local t; t=$(now)

    if [[ "$status" == "true" ]]; then
        state_load delinq "$pubkey"
        if [[ -z "$ST_START" ]]; then
            ST_START="$t"; ST_COUNT=1; ST_LAST=0
        else
            ((ST_COUNT++))
        fi

        if (( ST_LAST == 0 )); then
            # Not alarmed yet — fire once the delinquency is confirmed
            if (( ST_COUNT >= ALERT_THRESHOLD )); then
                send_alarm "🚨 ${name} — delinquent! (confirmed over ${ST_COUNT} checks)"
                ST_LAST="$t"
            fi
        elif (( t - ST_LAST >= ALERT_REPEAT_INTERVAL )); then
            local dur=$(( (t - ST_START) / 60 ))
            send_alarm "❗ ${name} — still delinquent! (for ${dur} min)"
            ST_LAST="$t"
        fi
        state_save delinq "$pubkey" "$ST_START" "$ST_COUNT" "$ST_LAST"
    else
        if state_active delinq "$pubkey"; then
            state_load delinq "$pubkey"
            if (( ST_LAST > 0 )); then   # only if a delinquency alarm was sent
                local dur=$(( (t - ST_START) / 60 ))
                send_alarm "✅ ${name} — back online! (was delinquent ${dur} min)"
            fi
            state_clear delinq "$pubkey"
        fi
    fi
}

# ============================================================================
#  CHECKS (medium loop: ping + balance)
# ============================================================================

check_ping() {
    local pubkey="$1" name="$2" ip="$3"
    local recv; recv=$(ping_received "$ip")
    [[ "$recv" == "-1" ]] && return   # ip not set — skip

    if [[ "$recv" == "0" ]]; then
        if ! state_active inet "$pubkey"; then
            local t; t=$(now)
            state_save inet "$pubkey" "$t" 1 "$t"
            send_alarm "📡 ${name} — connectivity lost (ping ${ip} failing)!"
        fi
    else
        if state_active inet "$pubkey"; then
            send_alarm "📡 ${name} — connectivity restored (${ip})"
            state_clear inet "$pubkey"
        fi
    fi
}

check_balance() {
    local pubkey="$1" name="$2" cluster="$3" warn="$4"
    local bal; bal=$(get_balance "$cluster" "$pubkey")
    [[ -z "$bal" ]] && return   # could not fetch — stay quiet

    if (( $(bc <<< "$bal < $warn") )); then
        local t; t=$(now)
        state_load lowbal "$pubkey"
        if [[ -z "$ST_START" ]] || (( t - ST_LAST >= BALANCE_REPEAT_INTERVAL )); then
            send_alarm "💰 ${name} — low identity balance: ${bal} SOL (threshold ${warn})"$'\n'"${pubkey}"
            state_save lowbal "$pubkey" "${ST_START:-$t}" 1 "$t"
        fi
    else
        state_active lowbal "$pubkey" && state_clear lowbal "$pubkey"
    fi
}

# ============================================================================
#  DASHBOARD SUMMARY (rich info to the info chat)
# ============================================================================

# Prepare per-cluster data for the summary (gossip + credit ranking).
summary_prep_cluster() {
    local cluster="$1"
    "$SOLANA_PATH" gossip "-u$cluster" > "$STATE_DIR/gossip_$cluster.txt" 2>/dev/null
    "$SOLANA_PATH" validators "-u$cluster" --sort=credits -r -n \
        > "$STATE_DIR/rank_$cluster.txt" 2>/dev/null
}

# Full dashboard for one node. build_summary <pubkey> <name> <cluster> <vote>
build_summary() {
    local pubkey="$1" name="$2" cluster="$3" vote="$4"
    local gossip_f="$STATE_DIR/gossip_$cluster.txt"
    local rank_f="$STATE_DIR/rank_$cluster.txt"

    local pub_short="${pubkey:0:10}"
    local ver; ver=$(validator_field "$cluster" "$pubkey" ".version")
    local ip; ip=$(grep "$pubkey" "$gossip_f" 2>/dev/null | awk '{print $1}' | head -1)
    local epoch_credits; epoch_credits=$(validator_field "$cluster" "$pubkey" ".epochCredits")
    [[ -z "$epoch_credits" ]] && epoch_credits=0

    # Cluster average skip
    local average; average=$(printf "%.2f" "$(cluster_avg_skip "$cluster")" 2>/dev/null)
    [[ -z "$average" ]] && average=0

    # Rank and credit leader (for relative % of the top validator)
    local rank; rank=$(grep "$pubkey" "$rank_f" 2>/dev/null | awk '{print $1}' | grep -oE '[0-9]+' | head -1)
    local leader_pk; leader_pk=$(sed -n '2p' "$rank_f" 2>/dev/null | awk '{print $3}')
    local leader_credits; leader_credits=$(validator_field "$cluster" "$leader_pk" ".epochCredits")
    local proc=0
    [[ -n "$leader_credits" && "$leader_credits" != "0" ]] && \
        proc=$(bc <<< "scale=2; $epoch_credits*100/$leader_credits")

    # Blocks: scheduled (whole epoch) / elapsed leader slots / produced / skipped
    local scheduled; scheduled=$(rpc_call "$cluster" \
        '{"jsonrpc":"2.0","id":1,"method":"getLeaderSchedule","params":[null,{"identity":"'"$pubkey"'"}]}' \
        | jq -r '.result."'"$pubkey"'" | length // 0' 2>/dev/null)
    [[ -z "$scheduled" || "$scheduled" == "null" ]] && scheduled=0

    local bp_json; bp_json=$(rpc_call "$cluster" \
        '{"jsonrpc":"2.0","id":1,"method":"getBlockProduction","params":[{"identity":"'"$pubkey"'"}]}')
    local leader_slots produced
    leader_slots=$(echo "$bp_json" | jq -r '.result.value.byIdentity."'"$pubkey"'"[0] // 0')
    produced=$(echo "$bp_json"     | jq -r '.result.value.byIdentity."'"$pubkey"'"[1] // 0')
    local skipped=$(( leader_slots - produced ))
    local skip=0
    (( leader_slots > 0 )) && skip=$(bc <<< "scale=2; $skipped*100/$leader_slots")
    local skip_icon="🟢"
    (( $(bc <<< "$skip > $average + $SKIP_DOP") )) && skip_icon="🔴"

    # Balances
    local balance vote_balance
    balance=$(get_balance "$cluster" "$pubkey"); [[ -z "$balance" ]] && balance="?"
    vote_balance=$(get_balance "$cluster" "$vote"); [[ -z "$vote_balance" ]] && vote_balance="?"

    # Stake: active / activating / deactivating
    local stakes; stakes=$("$SOLANA_PATH" stakes "$vote" "-u$cluster" --output json-compact 2>/dev/null)
    local active activating deactivating
    active=$(sum_stake_field "$stakes" activeStake)
    activating=$(sum_stake_field "$stakes" activatingStake)
    deactivating=$(sum_stake_field "$stakes" deactivatingStake)
    (( $(bc <<< "$activating > 0") ))   && activating="${activating}🟢"
    (( $(bc <<< "$deactivating > 0") )) && deactivating="${deactivating}⚠️"

    # Commission (earnings heuristic)
    local commission; commission=$(bc <<< "scale=3; (($epoch_credits*5) - ($produced*3750))/1000000")

    # Onboard (testnet only, until approval; hidden on mainnet)
    local onboard_line=""
    if [[ "$cluster" != "m" ]]; then
        local onboard; onboard=$(curl -s -X GET "https://api.solana.org/api/validators/$pubkey" 2>/dev/null | jq -r '.onboardingNumber // empty')
        [[ -n "$onboard" && "$onboard" != "null" ]] && onboard_line="onboard > [${onboard}]"
    fi

    # Build HTML
    printf '<b>%s</b> [%s] [%s]\n🌐 %s<code>\nAll:%s Done:%s skipped:%s\nskip:%s%s%% Average:%s%%\ncredits >[%s] [%s%%]\nrank>[%s] %s\nactive_stk >>>[%s]\nactivating >>>[%s]\ndeactivating >[%s]\nbalance>[%s]\nvote_balance>>[%s]\ncommission>[%s sol]</code>' \
        "$name" "$pub_short" "$ver" "$ip" \
        "$scheduled" "$leader_slots" "$skipped" \
        "$skip_icon" "$skip" "$average" \
        "$epoch_credits" "$proc" \
        "$rank" "$onboard_line" \
        "$active" "$activating" "$deactivating" \
        "$balance" "$vote_balance" "$commission"
}

# Cluster epoch info to the info chat
send_epoch_info() {
    local cluster="$1"
    local f="$STATE_DIR/epoch_$cluster.txt"
    "$SOLANA_PATH" epoch-info "-u$cluster" > "$f" 2>/dev/null
    local epoch percent end_time
    epoch=$(grep "Epoch:" "$f" | awk '{print $2}')
    percent=$(grep "Epoch Completed Percent" "$f" | awk '{print $4}' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    end_time=$(grep "Epoch Completed Time" "$f" | grep -o '(.*)' | sed 's/^(//;s/)$//')
    local label="Testnet"; [[ "$cluster" == "m" ]] && label="Mainnet"
    send_info "$(printf '<b>Epoch %s</b> <code>\n[%s] | [%s%%]\nEnd: %s</code>' "$label" "$epoch" "$percent" "$end_time")"
}

# Daily info: SFDP status + KYC
send_daily_info() {
    local pubkey="$1" name="$2"
    local info; info=$(curl -s -X GET "https://api.solana.org/api/validators/$pubkey" 2>/dev/null)
    local state kyc
    state=$(echo "$info" | jq -r '.state // "n/a"')
    kyc=$(echo "$info" | jq -r '.kycStatus // "n/a"')
    send_info "$(printf '<b>%s</b> [%s]<code>\n✅ SFDP: %s\n🔰 KYC: %s</code>' "$name" "${pubkey:0:8}" "$state" "$kyc")"
}

# ============================================================================
#  HELPERS
# ============================================================================

# Zero-padded hour comparison helper: hour_is <HH-target>
hour_is() { [[ "$1" == "$(printf '%02d' "$2")" ]]; }

# ============================================================================
#  MAIN LOOP
# ============================================================================

# Build the list of active nodes and the clusters in use
active_nodes=()
declare -A used_clusters
for pk in "${!NODE_NAME[@]}"; do
    [[ "${NODE_ENABLED[$pk]:-0}" == "1" ]] || continue
    active_nodes+=("$pk")
    used_clusters["${NODE_CLUSTER[$pk]}"]=1
done

if [[ ${#active_nodes[@]} -eq 0 ]]; then
    log_message "No active nodes in config.sh — nothing to monitor."
    exit 1
fi

log_message "Bot started. Active nodes: ${#active_nodes[@]}. Clusters: ${!used_clusters[*]}."

last_ping=0
last_summary=0
last_daily=""        # date of the last daily summary (YYYY-MM-DD)
last_heartbeat=""

while true; do
    t=$(now)

    # --- 1. Refresh the validators cache per cluster (one request) ---------
    #     Track which clusters have usable data this cycle so a failed RPC
    #     does not get mistaken for "every node recovered".
    declare -A ready=()
    for cl in "${!used_clusters[@]}"; do
        if refresh_validators "$cl" && cache_ready "$cl"; then
            ready["$cl"]=1
        fi
    done

    # --- 2. Fast delinquency check (only for clusters with fresh data) -----
    for pk in "${active_nodes[@]}"; do
        cl="${NODE_CLUSTER[$pk]}"
        [[ "${ready[$cl]:-0}" == "1" ]] || continue
        check_delinquency "$pk" "${NODE_NAME[$pk]}" "$cl"
    done

    # --- 3. Medium loop: ping + balance (independent of the cache) ---------
    if (( t - last_ping >= PING_INTERVAL )); then
        for pk in "${active_nodes[@]}"; do
            check_ping    "$pk" "${NODE_NAME[$pk]}" "${NODE_IP[$pk]:-}"
            check_balance "$pk" "${NODE_NAME[$pk]}" "${NODE_CLUSTER[$pk]}" "${NODE_BALANCE_WARN[$pk]:-1}"
        done
        last_ping=$t
    fi

    # --- 4. Dashboard summary + epoch --------------------------------------
    if (( t - last_summary >= SUMMARY_INTERVAL )); then
        for cl in "${!used_clusters[@]}"; do
            summary_prep_cluster "$cl"
        done
        for pk in "${active_nodes[@]}"; do
            send_info "$(build_summary "$pk" "${NODE_NAME[$pk]}" "${NODE_CLUSTER[$pk]}" "${NODE_VOTE[$pk]:-}")"
        done
        for cl in "${!used_clusters[@]}"; do
            send_epoch_info "$cl"
        done
        last_summary=$t
    fi

    # --- 5. Daily info (SFDP/KYC) — once a day at DAILY_INFO_HOUR -----------
    today=$(date +%Y-%m-%d)
    hour=$(date +%H)
    if hour_is "$hour" "$DAILY_INFO_HOUR" && [[ "$last_daily" != "$today" ]]; then
        for pk in "${active_nodes[@]}"; do
            send_daily_info "$pk" "${NODE_NAME[$pk]}"
        done
        last_daily=$today
    fi

    # --- 6. Heartbeat "bot alive" ------------------------------------------
    if (( HEARTBEAT_HOUR >= 0 )) && hour_is "$hour" "$HEARTBEAT_HOUR" && [[ "$last_heartbeat" != "$today" ]]; then
        send_info "🤖 Bot is running. Monitoring ${#active_nodes[@]} nodes."
        last_heartbeat=$today
    fi

    sleep "$CHECK_INTERVAL"
done
