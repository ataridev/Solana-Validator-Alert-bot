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
#
#  Env switches (debugging):
#    TG_DRYRUN=1   log messages instead of sending them to Telegram
#    ONE_SHOT=1    run a single iteration and exit
# ============================================================================
set -uo pipefail
export LC_NUMERIC="en_US.UTF-8"

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Logging (needed before the libraries are sourced) ----------------------
# Under systemd, stdout already goes to the journal (see the unit file), so
# writing bot.log as well would only duplicate it — and grow forever, with no
# rotation. JOURNAL_STREAM is set by systemd for exactly this purpose.
# On a manual run the file is still written, capped at LOG_MAX_KB.
log_message() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S %Z') - $1"
    echo "$line"
    [[ -n "${JOURNAL_STREAM:-}" ]] && return 0

    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null) || size=0
    if (( size > ${LOG_MAX_KB:-5120} * 1024 )); then
        mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
    fi
    printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null
    return 0
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
#  STARTUP CHECKS
#  All of these fail the daemon before the first poll. A monitoring bot that
#  starts misconfigured is worse than one that refuses to start: it looks alive
#  while quietly watching nothing.
# ============================================================================

# A second copy would double every alarm and race on the state files.
acquire_lock() {
    if ! command -v flock >/dev/null 2>&1; then
        log_message "WARN: flock is not available — single-instance guard is off"
        return 0
    fi
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_message "FATAL: another instance is already running (lock: $LOCK_FILE)"
        return 1
    fi
}

require_tools() {
    local missing=() t
    for t in curl jq bc timeout ping; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [[ -x "$SOLANA_PATH" ]] || missing+=("solana CLI at $SOLANA_PATH")
    if (( ${#missing[@]} )); then
        log_message "FATAL: missing dependencies: ${missing[*]}"
        return 1
    fi
}

# Verify the token now, so a typo surfaces at startup instead of at the first
# alarm — the one moment nobody is reading the log.
validate_secrets() {
    local missing=()
    [[ -n "${BOT_TOKEN:-}" ]]     || missing+=("BOT_TOKEN")
    [[ -n "${CHAT_ID_ALARM:-}" ]] || missing+=("CHAT_ID_ALARM")
    [[ -n "${CHAT_ID_INFO:-}" ]]  || missing+=("CHAT_ID_INFO")
    if (( ${#missing[@]} )); then
        log_message "FATAL: secrets.env is incomplete: ${missing[*]}"
        return 1
    fi

    if [[ "${TG_DRYRUN:-0}" == "1" ]]; then
        log_message "DRYRUN: skipping the getMe check"
        return 0
    fi

    local me
    me=$(curl --silent \
        --connect-timeout "${CONNECT_TIMEOUT:-5}" --max-time "${TG_TIMEOUT:-15}" \
        "https://api.telegram.org/bot${BOT_TOKEN}/getMe")
    if [[ "$(jq -r '.ok // empty' <<< "$me" 2>/dev/null)" != "true" ]]; then
        log_message "FATAL: Telegram rejected BOT_TOKEN: ${me:-<no response>}"
        return 1
    fi
    log_message "Telegram token OK: @$(jq -r '.result.username // "?"' <<< "$me")"
}

# A config typo otherwise shows up as a blank field in a dashboard hours later.
validate_config() {
    local ok=1 pk cl warn v
    # ${!v:-} so a parameter deleted from config.sh reports itself instead of
    # dying with "unbound variable" under set -u — which in an arithmetic
    # context does not merely fail, it exits the shell.
    #
    # Leading zeros are then stripped: bash arithmetic reads 08/09 as octal and
    # errors out. That error is silent in every context this config is used in
    # — `(( elapsed < CHECK_INTERVAL ))` would skip the sleep and spin the loop
    # at full tilt, and `printf '%02d'` would disable the daily report.
    for v in CHECK_INTERVAL PING_INTERVAL BALANCE_INTERVAL BALANCE_REPEAT_INTERVAL \
             SUMMARY_INTERVAL SKIP_CHECK_INTERVAL SKIP_ALERT_THRESHOLD \
             SKIP_ALERT_MIN_SLOTS SKIP_REPEAT_INTERVAL PING_ALERT_THRESHOLD \
             PING_REPEAT_INTERVAL VERSION_ALERT_THRESHOLD VERSION_REPEAT_INTERVAL \
             ALERT_THRESHOLD ALERT_REPEAT_INTERVAL DELINQUENT_SLOT_DISTANCE; do
        if [[ ! "${!v:-}" =~ ^[0-9]+$ ]]; then
            log_message "CONFIG: $v must be a positive integer (got '${!v:-<unset>}')"
            ok=0
            continue
        fi
        printf -v "$v" '%d' "$((10#${!v}))"
        if (( ${!v} < 1 )); then
            log_message "CONFIG: $v must be a positive integer (got '${!v}')"
            ok=0
        fi
    done

    # Hours: 0-23, or -1 to disable. Same octal trap, plus printf '%02d' turns
    # an out-of-range hour into one that simply never matches the clock.
    for v in DAILY_INFO_HOUR HEARTBEAT_HOUR; do
        if [[ ! "${!v:-}" =~ ^(-1|[0-9]{1,2})$ ]]; then
            log_message "CONFIG: $v must be an hour 0-23, or -1 to disable (got '${!v:-<unset>}')"
            ok=0
            continue
        fi
        [[ "${!v}" != "-1" ]] && printf -v "$v" '%d' "$((10#${!v}))"
        if (( ${!v} > 23 )); then
            log_message "CONFIG: $v must be an hour 0-23, or -1 to disable (got '${!v}')"
            ok=0
        fi
    done

    for pk in "${!NODE_NAME[@]}"; do
        [[ "${NODE_ENABLED[$pk]:-0}" == "1" ]] || continue

        [[ -n "${NODE_NAME[$pk]}" ]] || {
            log_message "CONFIG: $pk — NODE_NAME is empty"; ok=0; }

        cl="${NODE_CLUSTER[$pk]:-}"
        if [[ "$cl" != "t" && "$cl" != "m" ]]; then
            log_message "CONFIG: $pk — NODE_CLUSTER must be 't' or 'm' (got '$cl')"
            ok=0
        elif [[ -z "${RPC_URL[$cl]:-}" ]]; then
            log_message "CONFIG: $pk — no RPC_URL configured for cluster '$cl'"
            ok=0
        fi

        # Required since the fast loop looks a node up by its vote account.
        [[ -n "${NODE_VOTE[$pk]:-}" ]] || {
            log_message "CONFIG: $pk — NODE_VOTE is required (delinquency is checked by vote account)"
            ok=0; }

        warn="${NODE_BALANCE_WARN[$pk]:-}"
        if [[ -n "$warn" && ! "$warn" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            log_message "CONFIG: $pk — NODE_BALANCE_WARN must be a number (got '$warn')"
            ok=0
        fi
    done
    (( ok ))
}

# ============================================================================
#  CHECKS (fast)
# ============================================================================

# Delinquency watchdog. Two independent sticky alarms per node:
#   kind=delinq — voting, but behind
#   kind=gone   — absent from the vote accounts altogether
# Both run the same state machine (see alarm_step): confirmation over
# ALERT_THRESHOLD polls, repeats every ALERT_REPEAT_INTERVAL, recovery message
# only if an alarm was actually sent.
# State is keyed by identity pubkey (as before), while the lookup goes by vote
# account — that is what getVoteAccounts filters on.
check_delinquency() {
    local pubkey="$1" name="$2" cluster="$3" vote="$4"
    local st; st=$(vote_status "$cluster" "$vote")
    local t; t=$(now)

    case "$st" in
        unknown)
            # RPC blip — say nothing rather than invent a state. This is what
            # keeps a flaky endpoint from reading as "every node recovered".
            return
            ;;
        not_found)
            # Deliberately does not touch the delinq alarm: while the node is
            # missing we cannot tell whether it is still behind, so that state
            # is frozen rather than repeated or cleared. It resumes if the node
            # comes back delinquent, and clears via the ok branch if it does not.
            alarm_step gone "$pubkey" 1 "$t"
            case "$ALARM_DECISION" in
                first)
                    send_alarm "👻 ${name} — gone from the validator list! (confirmed over ${ST_COUNT} checks)"
                    ;;
                repeat)
                    send_alarm "👻 ${name} — still missing from the validator list! (for $(( (t - ST_START) / 60 )) min)"
                    ;;
            esac
            ;;
        delinquent)
            alarm_step gone "$pubkey" 0 "$t"
            [[ "$ALARM_DECISION" == "recover" ]] && \
                send_alarm "↩️ ${name} — back in the validator list (still delinquent)"

            alarm_step delinq "$pubkey" 1 "$t"
            case "$ALARM_DECISION" in
                first)
                    send_alarm "🚨 ${name} — delinquent! (confirmed over ${ST_COUNT} checks)"
                    ;;
                repeat)
                    send_alarm "❗ ${name} — still delinquent! (for $(( (t - ST_START) / 60 )) min)"
                    ;;
            esac
            ;;
        ok)
            alarm_step gone "$pubkey" 0 "$t"
            [[ "$ALARM_DECISION" == "recover" ]] && \
                send_alarm "↩️ ${name} — back in the validator list"

            alarm_step delinq "$pubkey" 0 "$t"
            [[ "$ALARM_DECISION" == "recover" ]] && \
                send_alarm "✅ ${name} — back online! (was delinquent $(( (t - ST_START) / 60 )) min)"
            ;;
    esac
    return 0
}

# ============================================================================
#  CHECKS (medium loop: ping + balance)
# ============================================================================

# Connectivity watchdog. Runs through alarm_step like every other check, which
# buys two things it lacked: a confirmation threshold, so one burst of ICMP loss
# (routinely rate-limited on transit links) is not an instant lost/restored
# flap; and a repeat, so an alarm that Telegram refused is re-sent instead of
# lost forever — the host losing upstream takes out the node check and the
# delivery path at the same time, which is exactly when it must not be dropped.
check_ping() {
    local pubkey="$1" name="$2" ip="$3"
    local recv; recv=$(ping_received "$ip")
    [[ "$recv" == "-1" ]] && return   # ip not set — skip

    # ping itself failed to run (missing binary, unsupported flag): a
    # non-numeric answer is not "0 packets", so stay quiet instead of
    # announcing a recovery we cannot vouch for.
    if [[ ! "$recv" =~ ^[0-9]+$ ]]; then
        log_message "WARN: ping to ${ip} produced no result for ${name}"
        return
    fi

    local t; t=$(now)
    local down=0
    [[ "$recv" == "0" ]] && down=1

    alarm_step inet "$pubkey" "$down" "$t" \
        "${PING_ALERT_THRESHOLD:-2}" "${PING_REPEAT_INTERVAL:-1800}"
    case "$ALARM_DECISION" in
        first)
            send_alarm "📡 ${name} — connectivity lost (ping ${ip} failing)!"
            ;;
        repeat)
            send_alarm "📡 ${name} — still unreachable (ping ${ip}, for $(( (t - ST_START) / 60 )) min)"
            ;;
        recover)
            send_alarm "📡 ${name} — connectivity restored (${ip})"
            ;;
    esac
    return 0
}

# Skip rate watchdog. The dashboard has always shown this number, but only
# hourly and only to whoever reads it — a validator skipping half its blocks is
# an alarm, not a data point.
check_skip() {
    [[ "${SKIP_ALERT_ENABLED:-1}" == "1" ]] || return 0
    local pubkey="$1" name="$2" cluster="$3"

    local bp; bp=$(block_production "$cluster" "$pubkey")
    # Not leader yet this epoch, or the call failed: nothing to judge.
    [[ -z "$bp" ]] && return 0

    local slots produced
    read -r slots produced <<< "$bp"
    [[ "$slots" =~ ^[0-9]+$ && "$produced" =~ ^[0-9]+$ ]] || return 0
    # Early in an epoch a handful of slots makes the percentage meaningless.
    (( slots < ${SKIP_ALERT_MIN_SLOTS:-20} )) && return 0

    local skipped=$(( slots - produced ))
    local skip; skip=$(bc <<< "scale=1; $skipped*100/$slots")
    local t; t=$(now)
    local over=0
    (( $(bc <<< "$skip >= ${SKIP_ALERT_THRESHOLD:-30}") )) && over=1

    alarm_step skip "$pubkey" "$over" "$t" \
        "${ALERT_THRESHOLD:-3}" "${SKIP_REPEAT_INTERVAL:-3600}"
    case "$ALARM_DECISION" in
        first)
            send_alarm "📉 ${name} — skip rate ${skip}% (over ${SKIP_ALERT_THRESHOLD}%), ${skipped} of ${slots} leader slots missed"
            ;;
        repeat)
            send_alarm "📉 ${name} — skip rate still ${skip}% (${skipped}/${slots} leader slots)"
            ;;
        recover)
            send_alarm "✅ ${name} — skip rate back to ${skip}%"
            ;;
    esac
    return 0
}

# Version watchdog: falling behind the cluster is how a validator quietly stops
# being able to vote after a feature gate activates.
check_version() {
    [[ "${VERSION_ALERT_ENABLED:-1}" == "1" ]] || return 0
    local pubkey="$1" name="$2" cluster="$3"

    node_facts "$cluster" "$pubkey" || return 0
    local mine="$NF_VERSION"
    [[ -z "$mine" || "$mine" == "unknown" ]] && return 0

    local majority; majority=$(cluster_majority_version "$cluster")
    [[ -z "$majority" ]] && return 0

    local t behind=0; t=$(now)
    version_lt "$mine" "$majority" && behind=1

    alarm_step version "$pubkey" "$behind" "$t" \
        "${VERSION_ALERT_THRESHOLD:-2}" "${VERSION_REPEAT_INTERVAL:-86400}"
    case "$ALARM_DECISION" in
        first|repeat)
            send_alarm "⬆️ ${name} — running ${mine}, cluster majority is on ${majority}"
            ;;
        recover)
            send_alarm "✅ ${name} — version ${mine} is no longer behind the cluster"
            ;;
    esac
    return 0
}

# Balance watchdog. threshold=1 — a balance reading does not flap, so there is
# nothing to confirm; it alarms on the first low reading, as before, and repeats
# every BALANCE_REPEAT_INTERVAL. No recovery message: a topped-up balance is not
# news worth a notification.
check_balance() {
    local pubkey="$1" name="$2" cluster="$3" warn="$4"
    local bal; bal=$(get_balance "$cluster" "$pubkey")
    [[ -z "$bal" ]] && return 0   # could not fetch — stay quiet

    local t; t=$(now)
    local low=0
    (( $(bc <<< "$bal < $warn") )) && low=1

    alarm_step lowbal "$pubkey" "$low" "$t" 1 "${BALANCE_REPEAT_INTERVAL:-3600}"
    case "$ALARM_DECISION" in
        first|repeat)
            send_alarm "💰 ${name} — low identity balance: ${bal} SOL (threshold ${warn})"$'\n'"${pubkey}"
            ;;
    esac
    return 0
}

# ============================================================================
#  DASHBOARD SUMMARY (rich info to the info chat)
# ============================================================================

# Solana Foundation delegation program record: sfdp_get <pubkey>
sfdp_get() {
    http_get "https://api.solana.org/api/validators/$1" 2>/dev/null
}

# Commission actually paid out, for the dashboard line:
# summary_commission <cluster> <vote> <current_epoch> — prints "1.23 sol | ep 41"
# or "n/a".
# The old formula estimated this from credits, which stopped meaning anything
# when timely vote credits raised the per-slot maximum from 1 to 16 (mainnet,
# epoch 703). getInflationReward returns the real number. The current epoch has
# no reward yet, hence epoch - 1.
summary_commission() {
    local cluster="$1" vote="$2" epoch="${3:-0}"
    [[ -z "$vote" ]] && { echo "n/a"; return; }
    (( epoch > 0 )) || { echo "n/a"; return; }

    local reward_epoch=$(( epoch - 1 )) lamports
    lamports=$(inflation_reward "$cluster" "$vote" "$reward_epoch")
    if [[ -z "$lamports" ]]; then
        echo "n/a"
        return
    fi
    echo "$(lamports_to_sol "$lamports") sol | ep ${reward_epoch}"
}

# Onboarding line, testnet only and only while in the program:
# sfdp_onboard_line <cluster> <pubkey>
sfdp_onboard_line() {
    local cluster="$1" pubkey="$2"
    [[ "$cluster" == "m" || "${SFDP_ENABLED:-1}" != "1" ]] && return

    local onboard; onboard=$(sfdp_get "$pubkey" | jq -r '.onboardingNumber // empty')
    [[ -n "$onboard" && "$onboard" != "null" ]] && \
        printf 'onboard > [%s]' "$(html_escape "$onboard")"
    return 0
}

# Full dashboard for one node.
# build_summary <pubkey> <name> <cluster> <vote> <current_epoch> <ip>
build_summary() {
    local pubkey="$1" name="$2" cluster="$3" vote="$4" epoch="${5:-0}" ip="${6:-}"

    # Version, credits, stake, rank, cluster leader and average skip — one jq
    # pass over the cached list.
    node_facts "$cluster" "$pubkey" || {
        printf '<b>%s</b> [%s]\n<code>no data in the validator list</code>' \
            "$(html_escape "$name")" "${pubkey:0:10}"
        return
    }

    local pub_short="${pubkey:0:10}"
    local ver="$NF_VERSION"
    local epoch_credits="$NF_CREDITS"
    local rank="$NF_RANK"

    # Fall back to gossip only when config has no IP for this node.
    [[ -z "$ip" ]] && ip=$(node_ip "$cluster" "$pubkey")

    local average; average=$(printf "%.2f" "$NF_AVG_SKIP" 2>/dev/null)
    [[ -z "$average" ]] && average=0

    # Credits relative to the cluster leader
    local proc=0
    [[ "$NF_TOP_CREDITS" != "0" ]] && \
        proc=$(bc <<< "scale=2; $epoch_credits*100/$NF_TOP_CREDITS")

    # Blocks: scheduled (whole epoch) / elapsed leader slots / produced / skipped
    local scheduled; scheduled=$(rpc_call "$cluster" \
        '{"jsonrpc":"2.0","id":1,"method":"getLeaderSchedule","params":[null,{"identity":"'"$pubkey"'"}]}' \
        | jq -r '.result."'"$pubkey"'" | length // 0' 2>/dev/null)
    [[ -z "$scheduled" || "$scheduled" == "null" ]] && scheduled=0

    local leader_slots=0 produced=0
    local bp; bp=$(block_production "$cluster" "$pubkey")
    [[ -n "$bp" ]] && read -r leader_slots produced <<< "$bp"
    local skipped=$(( leader_slots - produced ))
    local skip=0
    (( leader_slots > 0 )) && skip=$(bc <<< "scale=2; $skipped*100/$leader_slots")
    local skip_icon="🟢"
    (( $(bc <<< "$skip > $average + $SKIP_DOP") )) && skip_icon="🔴"

    # Balances
    local balance vote_balance
    balance=$(get_balance "$cluster" "$pubkey"); [[ -z "$balance" ]] && balance="?"
    vote_balance=$(get_balance "$cluster" "$vote"); [[ -z "$vote_balance" ]] && vote_balance="?"

    # Active stake comes free with the cached vote accounts. Activating and
    # deactivating need `solana stakes` — a getProgramAccounts scan over the
    # whole stake program — so they moved to the daily report instead of
    # running every hour.
    local active; active=$(lamports_to_sol "$NF_STAKE")

    local commission; commission=$(summary_commission "$cluster" "$vote" "$epoch")
    local onboard_line; onboard_line=$(sfdp_onboard_line "$cluster" "$pubkey")

    # Build HTML
    printf '<b>%s</b> [%s] [%s]\n🌐 %s<code>\nAll:%s Done:%s skipped:%s\nskip:%s%s%% Average:%s%%\ncredits >[%s] [%s%%]\nrank>[%s] %s\nactive_stk >>>[%s]\nbalance>[%s]\nvote_balance>>[%s]\ncommission>[%s]</code>' \
        "$(html_escape "$name")" "$pub_short" "$(html_escape "$ver")" "$(html_escape "$ip")" \
        "$scheduled" "$leader_slots" "$skipped" \
        "$skip_icon" "$skip" "$average" \
        "$epoch_credits" "$proc" \
        "$rank" "$onboard_line" \
        "$active" \
        "$balance" "$vote_balance" "$commission"
}

# Cluster epoch info to the info chat.
# Straight from getEpochInfo — the CLI's text output was being scraped with
# grep/awk, which breaks whenever its formatting changes.
send_epoch_info() {
    local cluster="$1"
    local j; j=$(rpc_call "$cluster" '{"jsonrpc":"2.0","id":1,"method":"getEpochInfo"}')
    local epoch idx total
    epoch=$(jq -r '.result.epoch // empty'        <<< "$j" 2>/dev/null)
    idx=$(jq -r   '.result.slotIndex // empty'    <<< "$j" 2>/dev/null)
    total=$(jq -r '.result.slotsInEpoch // empty' <<< "$j" 2>/dev/null)
    if [[ -z "$epoch" || -z "$idx" || -z "$total" ]] || (( total == 0 )); then
        log_message "WARN: could not fetch epoch info for cluster $cluster"
        return
    fi

    local percent; percent=$(bc <<< "scale=1; $idx*100/$total")
    # Slots are ~400 ms, so this is an estimate — same as the CLI's own.
    local secs=$(( (total - idx) * 4 / 10 ))
    local d=$(( secs / 86400 )) h=$(( (secs % 86400) / 3600 )) m=$(( (secs % 3600) / 60 ))
    local eta="${h}h ${m}m"
    (( d > 0 )) && eta="${d}d ${h}h ${m}m"

    local label="Testnet"; [[ "$cluster" == "m" ]] && label="Mainnet"
    send_info "$(printf '<b>Epoch %s</b> <code>\n[%s] | [%s%%]\nEnds in: ~%s</code>' \
        "$label" "$epoch" "$percent" "$eta")"
}

# Daily info: SFDP status + KYC
send_daily_info() {
    [[ "${SFDP_ENABLED:-1}" == "1" ]] || return
    local pubkey="$1" name="$2"
    local info; info=$(sfdp_get "$pubkey")
    local state kyc
    state=$(echo "$info" | jq -r '.state // "n/a"')
    kyc=$(echo "$info" | jq -r '.kycStatus // "n/a"')
    send_info "$(printf '<b>%s</b> [%s]<code>\n✅ SFDP: %s\n🔰 KYC: %s</code>' \
        "$(html_escape "$name")" "${pubkey:0:8}" "$(html_escape "$state")" "$(html_escape "$kyc")")"
}

# Daily stake flows. This is the one caller of `solana stakes`, which scans the
# whole stake program — far too heavy for the hourly dashboard, and the numbers
# only move once per epoch anyway.
send_daily_stake() {
    local pubkey="$1" name="$2" cluster="$3" vote="$4"
    [[ -z "$vote" ]] && return

    local stakes; stakes=$(solana_cli stakes "$vote" "-u$cluster" --output json-compact 2>/dev/null)
    if [[ -z "$stakes" ]] || ! jq -e 'type == "array"' <<< "$stakes" >/dev/null 2>&1; then
        log_message "WARN: could not fetch stakes for $name"
        return
    fi

    local activating deactivating
    activating=$(sum_stake_field "$stakes" activatingStake)
    deactivating=$(sum_stake_field "$stakes" deactivatingStake)
    (( $(bc <<< "$activating > 0") ))   && activating="${activating}🟢"
    (( $(bc <<< "$deactivating > 0") )) && deactivating="${deactivating}⚠️"

    send_info "$(printf '<b>%s</b> [%s]<code>\nactivating >>>[%s]\ndeactivating >[%s]</code>' \
        "$(html_escape "$name")" "${pubkey:0:8}" "$activating" "$deactivating")"
}

# The hourly report: refresh each cluster's cache, then a dashboard per node
# and an epoch line per cluster. The full validator list is only pulled here —
# the fast loop does not need it.
send_hourly_report() {
    # local -A, not declare -A: at main-loop scope these are globals, and a
    # cluster that failed to refresh would keep last hour's ready flag.
    local -A ready=() cluster_epoch=()
    local cl pk

    for cl in "${!used_clusters[@]}"; do
        if refresh_validators "$cl" && cache_ready "$cl"; then
            ready["$cl"]=1
        fi
        # Once per cluster: build_summary needs it for the previous epoch's reward.
        cluster_epoch["$cl"]=$(current_epoch "$cl")
    done

    for pk in "${active_nodes[@]}"; do
        cl="${NODE_CLUSTER[$pk]}"
        # No fresh data — skip rather than report from a stale cache.
        [[ "${ready[$cl]:-0}" == "1" ]] || continue
        send_info "$(build_summary "$pk" "${NODE_NAME[$pk]}" "$cl" \
            "${NODE_VOTE[$pk]:-}" "${cluster_epoch[$cl]:-0}" "${NODE_IP[$pk]:-}")"
        # Rides the cache refresh — the data is already here.
        check_version "$pk" "${NODE_NAME[$pk]}" "$cl"
    done

    for cl in "${!used_clusters[@]}"; do
        send_epoch_info "$cl"
    done
}

# ============================================================================
#  HELPERS
# ============================================================================

# Zero-padded hour comparison: hour_is <current_HH> <target_hour>
hour_is() { [[ "$1" == "$(printf '%02d' "$2")" ]]; }

# ============================================================================
#  MAIN LOOP
# ============================================================================

acquire_lock     || exit 1
require_tools    || exit 1
validate_secrets || exit 1
validate_config  || { log_message "FATAL: config.sh has errors (see above)"; exit 1; }

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
[[ "${TG_DRYRUN:-0}" == "1" ]] && log_message "DRYRUN mode — no messages will be sent."

# Timers come off disk: otherwise every restart replays the hourly summary, and
# a restart during DAILY_INFO_HOUR/HEARTBEAT_HOUR re-sends that day's message.
last_ping=0
last_balance=0
last_skip=0
last_summary=$(mark_get summary); : "${last_summary:=0}"
last_daily=$(mark_get daily)          # date of the last daily summary (YYYY-MM-DD)
last_heartbeat=$(mark_get heartbeat)

while true; do
    t=$(now)

    # --- 1. Fast delinquency check: one small filtered RPC call per node ---
    #     An unreadable answer yields "unknown" and stays silent, so an RPC
    #     blip is never mistaken for "every node recovered".
    for pk in "${active_nodes[@]}"; do
        check_delinquency "$pk" "${NODE_NAME[$pk]}" "${NODE_CLUSTER[$pk]}" "${NODE_VOTE[$pk]}"
    done

    # --- 2. Ping ------------------------------------------------------------
    if (( t - last_ping >= PING_INTERVAL )); then
        for pk in "${active_nodes[@]}"; do
            check_ping "$pk" "${NODE_NAME[$pk]}" "${NODE_IP[$pk]:-}"
        done
        last_ping=$t
    fi

    # --- 3. Balance (own cadence: it drains over hours, not seconds) --------
    if (( t - last_balance >= BALANCE_INTERVAL )); then
        for pk in "${active_nodes[@]}"; do
            check_balance "$pk" "${NODE_NAME[$pk]}" "${NODE_CLUSTER[$pk]}" "${NODE_BALANCE_WARN[$pk]:-1}"
        done
        last_balance=$t
    fi

    # --- 4. Skip rate -------------------------------------------------------
    if (( t - last_skip >= SKIP_CHECK_INTERVAL )); then
        for pk in "${active_nodes[@]}"; do
            check_skip "$pk" "${NODE_NAME[$pk]}" "${NODE_CLUSTER[$pk]}"
        done
        last_skip=$t
    fi

    # --- 5. Dashboard summary + epoch --------------------------------------
    if (( t - last_summary >= SUMMARY_INTERVAL )); then
        send_hourly_report
        last_summary=$t
        mark_set summary "$t"
    fi

    # --- 6. Daily info (SFDP/KYC + stake flows) at DAILY_INFO_HOUR -----------
    today=$(date +%Y-%m-%d)
    hour=$(date +%H)
    if hour_is "$hour" "$DAILY_INFO_HOUR" && [[ "$last_daily" != "$today" ]]; then
        for pk in "${active_nodes[@]}"; do
            send_daily_info  "$pk" "${NODE_NAME[$pk]}"
            send_daily_stake "$pk" "${NODE_NAME[$pk]}" "${NODE_CLUSTER[$pk]}" "${NODE_VOTE[$pk]:-}"
        done
        last_daily=$today
        mark_set daily "$today"
    fi

    # --- 7. Heartbeat "bot alive" ------------------------------------------
    if (( HEARTBEAT_HOUR >= 0 )) && hour_is "$hour" "$HEARTBEAT_HOUR" && [[ "$last_heartbeat" != "$today" ]]; then
        send_info "🤖 Bot is running. Monitoring ${#active_nodes[@]} nodes."
        last_heartbeat=$today
        mark_set heartbeat "$today"
    fi

    if [[ "${ONE_SHOT:-0}" == "1" ]]; then
        log_message "ONE_SHOT: one iteration done, exiting."
        break
    fi

    # Sleep the remainder of the interval, not a full interval on top of the
    # work: otherwise CHECK_INTERVAL is a floor that drifts with RPC latency,
    # and the real polling period is anyone's guess. A cycle that overran the
    # interval starts the next one immediately.
    elapsed=$(( $(now) - t ))
    (( elapsed < 0 )) && elapsed=0
    if (( elapsed < CHECK_INTERVAL )); then
        sleep $(( CHECK_INTERVAL - elapsed ))
    fi
done
