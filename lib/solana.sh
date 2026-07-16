#!/bin/bash
# ============================================================================
#  Wrappers around the solana CLI and RPC.
#
#  Delinquency (the fast loop) goes through vote_status: one small filtered RPC
#  call per node. The full validator list is only pulled for the hourly
#  dashboard, cached per cluster and reused for every node in it.
# ============================================================================

# Run the solana CLI under a hard timeout: solana_cli <args...>
# A hung CLI call would otherwise freeze the whole loop indefinitely.
solana_cli() {
    timeout "${CLI_TIMEOUT:-60}" "$SOLANA_PATH" "$@"
}

# Plain HTTP GET with timeouts: http_get <url>
http_get() {
    curl --silent \
        --connect-timeout "${CONNECT_TIMEOUT:-5}" \
        --max-time "${RPC_TIMEOUT:-15}" \
        "$1"
}

# Path to the cached validators list for a cluster
validators_cache_file() {
    echo "$STATE_DIR/validators_$1.json"
}

# Refresh the validators cache for a cluster: refresh_validators <cluster>
# Returns 0 on success, 1 on an empty/broken response (cache is left intact).
refresh_validators() {
    local cluster="$1"
    local out tmp
    tmp="$(validators_cache_file "$cluster").tmp"

    out=$(solana_cli validators "-u$cluster" \
            --delinquent-slot-distance "$DELINQUENT_SLOT_DISTANCE" \
            --output json-compact 2>/dev/null)

    # Make sure it is valid JSON with a validators array
    if [[ -n "$out" ]] && echo "$out" | jq -e '.validators' >/dev/null 2>&1; then
        echo "$out" > "$tmp"
        mv "$tmp" "$(validators_cache_file "$cluster")"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    log_message "WARN: empty/broken validators response for cluster $cluster"
    return 1
}

# Whether a usable validators cache exists for a cluster: cache_ready <cluster>
cache_ready() {
    [[ -s "$(validators_cache_file "$1")" ]]
}

# Node health straight from RPC: vote_status <cluster> <vote_pubkey>
#
# One getVoteAccounts filtered down to a single vote account — a few hundred
# bytes. The alternative, `solana validators`, downloads the entire cluster
# list (megabytes on mainnet) to read one boolean.
#   delinquentSlotDistance   — our own threshold, applied by the RPC node
#   keepUnstakedDelinquents  — without it a stake-less delinquent node silently
#                              drops out of the response and reads as "gone"
#
# Prints exactly one of:
#   ok         — voting
#   delinquent — behind by more than DELINQUENT_SLOT_DISTANCE slots
#   not_found  — in neither list: dropped out of the cluster entirely
#   unknown    — no/failed response; caller must stay quiet rather than guess
# "not_found" must never be treated as recovery: a vanished validator is a
# problem, not a node that got better.
vote_status() {
    local cluster="$1" vote="$2" resp out
    resp=$(rpc_call "$cluster" \
        '{"jsonrpc":"2.0","id":1,"method":"getVoteAccounts","params":[{"votePubkey":"'"$vote"'","delinquentSlotDistance":'"$DELINQUENT_SLOT_DISTANCE"',"keepUnstakedDelinquents":true}]}')

    if ! out=$(jq -r '
        if .result then
            if   (.result.delinquent | length) > 0 then "delinquent"
            elif (.result.current    | length) > 0 then "ok"
            else "not_found" end
        else "unknown" end' <<< "$resp" 2>/dev/null) || [[ -z "$out" ]]; then
        echo "unknown"
        return
    fi
    echo "$out"
}

# Everything the dashboard needs about one node, in a single pass over the
# cached list: node_facts <cluster> <identity_pubkey>
# Sets NF_VERSION NF_CREDITS NF_STAKE NF_RANK NF_TOP_CREDITS NF_AVG_SKIP.
# Returns 1 if the cache is unreadable or the node is not in it.
#
# This replaces four validator_field calls (each re-parsing the whole
# multi-megabyte file) plus a second `solana validators --sort=credits` run
# that downloaded the very same list again just to read a rank off its text.
node_facts() {
    local cluster="$1" pubkey="$2" out
    NF_VERSION=""; NF_CREDITS=0; NF_STAKE=0
    NF_RANK=""; NF_TOP_CREDITS=0; NF_AVG_SKIP=0

    # Fields are joined with US (\x1f), not a tab: tab is IFS whitespace, so
    # bash would collapse runs of them and drop a leading one — a node with no
    # version (absent from gossip) would silently shift stake into credits.
    out=$(jq -r --arg pk "$pubkey" '
        (.validators | sort_by(-.epochCredits)) as $sorted
        | ($sorted | map(.identityPubkey) | index($pk)) as $idx
        | (if $idx == null then null else $sorted[$idx] end) as $me
        | [ ($me.version // ""),
            ($me.epochCredits // 0),
            ($me.activatedStake // 0),
            (if $idx == null then "" else ($idx + 1) end),
            ($sorted[0].epochCredits // 0),
            (.averageStakeWeightedSkipRate // 0) ]
        | map(tostring) | join("\u001f")' \
        "$(validators_cache_file "$cluster")" 2>/dev/null) || return 1
    [[ -z "$out" ]] && return 1

    IFS=$'\x1f' read -r NF_VERSION NF_CREDITS NF_STAKE NF_RANK NF_TOP_CREDITS NF_AVG_SKIP <<< "$out"
    [[ -n "$NF_RANK" ]]
}

# The version running the most stake in a cluster: cluster_majority_version <cluster>
# Weighted by stake, not by node count: a thousand idle nodes on an old build
# do not make it the version to be on. Delinquent nodes are excluded.
cluster_majority_version() {
    jq -r '[.validators[]
            | select(.delinquent | not)
            | select(.version != null and .version != "unknown")
            | {version: .version, stake: (.activatedStake // 0)}]
           | group_by(.version)
           | map({version: .[0].version, stake: (map(.stake) | add)})
           | sort_by(-.stake)
           | .[0].version // empty' \
        "$(validators_cache_file "$1")" 2>/dev/null
}

# version_lt <a> <b> — true when version a is older than b.
# Plain numeric compare per component; sort -V would be simpler but is a GNU
# extension, and suffixes like "2.1.0-jito" must not confuse it.
version_lt() {
    local IFS=.
    local -a a b
    read -ra a <<< "$1"
    read -ra b <<< "$2"
    local i x y
    for (( i = 0; i < 3; i++ )); do
        x="${a[i]:-0}"; y="${b[i]:-0}"
        x="${x%%[^0-9]*}"; y="${y%%[^0-9]*}"
        (( 10#${x:-0} < 10#${y:-0} )) && return 0
        (( 10#${x:-0} > 10#${y:-0} )) && return 1
    done
    return 1
}

# Leader slots and produced blocks this epoch: block_production <cluster> <identity>
# Prints "<leader_slots> <produced>", or nothing when the node has not been
# leader yet (or the call failed).
block_production() {
    local cluster="$1" pubkey="$2" resp
    resp=$(rpc_call "$cluster" \
        '{"jsonrpc":"2.0","id":1,"method":"getBlockProduction","params":[{"identity":"'"$pubkey"'"}]}')
    jq -r --arg pk "$pubkey" \
        '.result.value.byIdentity[$pk] // empty | "\(.[0]) \(.[1])"' <<< "$resp" 2>/dev/null
}

# Gossip IP of a node: node_ip <cluster> <identity_pubkey>
# Only used when NODE_IP is not set in config.sh — `solana gossip` used to
# download the entire gossip table for this one field.
node_ip() {
    local cluster="$1" pubkey="$2"
    rpc_call "$cluster" '{"jsonrpc":"2.0","id":1,"method":"getClusterNodes"}' \
        | jq -r --arg pk "$pubkey" \
            'first(.result[]? | select(.pubkey == $pk) | .gossip // empty) // empty' 2>/dev/null \
        | cut -d: -f1
}

# Generic RPC call: rpc_call <cluster> <json_body>
rpc_call() {
    local cluster="$1" body="$2"
    curl --silent \
        --connect-timeout "${CONNECT_TIMEOUT:-5}" \
        --max-time "${RPC_TIMEOUT:-15}" \
        -X POST "${RPC_URL[$cluster]}" \
        -H 'Content-Type: application/json' -d "$body"
}

# lamports_to_sol <lamports> — SOL with 2 decimals, with the leading zero that
# bc drops on values like .50
lamports_to_sol() {
    local out
    out=$(echo "scale=2; ${1:-0}/1000000000" | bc 2>/dev/null)
    [[ -z "$out" ]] && out=0
    [[ "${out:0:1}" == "." ]] && out="0$out"
    echo "$out"
}

# Address balance in SOL (2 decimals): get_balance <cluster> <pubkey>
get_balance() {
    local cluster="$1" pubkey="$2" lamports
    lamports=$(rpc_call "$cluster" \
        '{"jsonrpc":"2.0","id":1,"method":"getBalance","params":["'"$pubkey"'"]}' \
        | jq -r '.result.value // empty')
    [[ -z "$lamports" || "$lamports" == "null" ]] && { echo ""; return 1; }
    lamports_to_sol "$lamports"
}

# Current epoch number: current_epoch <cluster>
current_epoch() {
    rpc_call "$1" '{"jsonrpc":"2.0","id":1,"method":"getEpochInfo"}' \
        | jq -r '.result.epoch // empty' 2>/dev/null
}

# Inflation reward for an address in a given epoch, in lamports (empty if none).
# inflation_reward <cluster> <pubkey> <epoch>
# On a vote account this is the validator's commission cut — the real number,
# paid out and recorded on chain, rather than an estimate.
# Only completed epochs have a reward, so the caller must ask for a past one.
inflation_reward() {
    local cluster="$1" pubkey="$2" epoch="$3"
    rpc_call "$cluster" \
        '{"jsonrpc":"2.0","id":1,"method":"getInflationReward","params":[["'"$pubkey"'"],{"epoch":'"$epoch"'}]}' \
        | jq -r '.result[0].amount // empty' 2>/dev/null
}

# Sum a lamports stake field across all stake accounts, in SOL (2 decimals).
# sum_stake_field <stakes_json> <field>   e.g. sum_stake_field "$json" activatingStake
sum_stake_field() {
    local stakes_json="$1" field="$2" sum
    sum=$(echo "$stakes_json" | jq -c ".[] | .$field // 0" 2>/dev/null | paste -sd+ - | bc 2>/dev/null)
    [[ -z "$sum" ]] && sum=0
    lamports_to_sol "$sum"
}

# Ping: prints the number of received packets (0 = node unreachable),
# "-1" when no ip is configured, or nothing at all if ping could not run.
# -W bounds the wait per packet and -w the whole run: this sits in the main
# loop, so an unreachable host must cost a bounded couple of seconds.
ping_received() {
    local ip="$1"
    [[ -z "$ip" ]] && { echo "-1"; return; }   # -1 = ip not set, skip the check
    ping -c "$PING_COUNT" -W "${PING_TIMEOUT:-1}" -w "${PING_DEADLINE:-3}" "$ip" 2>/dev/null \
        | grep transmitted | awk '{print $4}'
}
