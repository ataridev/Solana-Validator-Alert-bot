#!/bin/bash
# ============================================================================
#  Wrappers around the solana CLI and RPC.
#  Key optimization: a single `solana validators` call per cluster per cycle,
#  the result is cached to a file and reused for every node in that cluster.
# ============================================================================

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

    out=$("$SOLANA_PATH" validators "-u$cluster" \
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

# Read a validator field from the cache: validator_field <cluster> <pubkey> <jq_field>
# Example: validator_field t IDENTITY .delinquent
validator_field() {
    local cluster="$1" pubkey="$2" field="$3"
    jq -r --arg pk "$pubkey" \
        ".validators[] | select(.identityPubkey == \$pk) | $field // empty" \
        "$(validators_cache_file "$cluster")" 2>/dev/null
}

# Cluster average skip rate (averageStakeWeightedSkipRate)
cluster_avg_skip() {
    jq -r '.averageStakeWeightedSkipRate // 0' "$(validators_cache_file "$1")" 2>/dev/null
}

# Generic RPC call: rpc_call <cluster> <json_body>
rpc_call() {
    local cluster="$1" body="$2"
    curl --silent -X POST "${RPC_URL[$cluster]}" \
        -H 'Content-Type: application/json' -d "$body"
}

# Address balance in SOL (2 decimals): get_balance <cluster> <pubkey>
get_balance() {
    local cluster="$1" pubkey="$2" lamports bal
    lamports=$(rpc_call "$cluster" \
        '{"jsonrpc":"2.0","id":1,"method":"getBalance","params":["'"$pubkey"'"]}' \
        | jq -r '.result.value // empty')
    [[ -z "$lamports" || "$lamports" == "null" ]] && { echo ""; return 1; }
    bal=$(echo "scale=2; $lamports/1000000000" | bc)
    # leading zero for values like .50
    [[ "${bal:0:1}" == "." ]] && bal="0$bal"
    echo "$bal"
}

# Sum a lamports stake field across all stake accounts, in SOL (2 decimals).
# sum_stake_field <stakes_json> <field>   e.g. sum_stake_field "$json" activeStake
sum_stake_field() {
    local stakes_json="$1" field="$2" sum out
    sum=$(echo "$stakes_json" | jq -c ".[] | .$field // 0" 2>/dev/null | paste -sd+ - | bc 2>/dev/null)
    [[ -z "$sum" ]] && sum=0
    out=$(echo "scale=2; $sum/1000000000" | bc 2>/dev/null)
    [[ -z "$out" ]] && out=0
    [[ "${out:0:1}" == "." ]] && out="0$out"
    echo "$out"
}

# Ping: returns the number of received packets (0 = node unreachable)
ping_received() {
    local ip="$1"
    [[ -z "$ip" ]] && { echo "-1"; return; }   # -1 = ip not set, skip the check
    ping -c "$PING_COUNT" "$ip" 2>/dev/null | grep transmitted | awk '{print $4}'
}
