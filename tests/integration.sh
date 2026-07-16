#!/bin/bash
# ============================================================================
#  Integration tests: a full bot.sh run against a local fake RPC and a fake
#  solana CLI, in TG_DRYRUN=1 ONE_SHOT=1 mode. No real network, no messages.
#  Run: tests/integration.sh   (or tests/run.sh for everything)
# ============================================================================
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$TESTS_DIR/.." && pwd)"
WORK=$(mktemp -d)
cp -r "$SRC"/{bot.sh,config.sh,lib} "$WORK/"
mkdir -p "$WORK/bin" "$WORK/state"
export PATH="$WORK/bin:$PATH"

RPC_PORT=${RPC_PORT:-18899}

# Stubs only where the real tool is missing (macOS lacks both; CI does not).
# Never shadow the real thing: the bot's own timeout handling must be exercised.
if ! command -v timeout >/dev/null 2>&1; then
    printf '#!/bin/bash\nshift\nexec "$@"\n' > "$WORK/bin/timeout"
    chmod +x "$WORK/bin/timeout"
    echo "note: stubbing timeout(1) — not available here"
fi
if ! command -v flock >/dev/null 2>&1; then
    printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/flock"
    chmod +x "$WORK/bin/flock"
    echo "note: stubbing flock(1) — not available here"
fi

# Fake solana CLI: logs which subcommand was asked for, so a test can assert
# that the fast loop never touches it.
cat > "$WORK/bin/fake-solana" <<SH
#!/bin/bash
echo "\$1" >> "$WORK/cli_calls.log"
if [ "\$1" = "validators" ] && [ -f "$WORK/fake_validators.json" ]; then
    cat "$WORK/fake_validators.json"
else
    echo ""
fi
SH
chmod +x "$WORK/bin/fake-solana"

# Fake RPC: reads its reply at request time, per method when reply_<method> exists.
echo '{}' > "$WORK/rpc_reply"
: > "$WORK/rpc_calls.log"
: > "$WORK/cli_calls.log"
python3 "$TESTS_DIR/fake_rpc.py" "$WORK/rpc_reply" "$WORK/rpc_calls.log" "$RPC_PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; rm -rf "$WORK"' EXIT
sleep 0.5

cat > "$WORK/secrets.env" <<'ENV'
BOT_TOKEN="123:FAKE"
CHAT_ID_ALARM="-100"
CHAT_ID_INFO="-101"
ENV

cat > "$WORK/config.sh" <<CFG
SOLANA_PATH="$WORK/bin/fake-solana"
declare -A RPC_URL
RPC_URL["t"]="http://127.0.0.1:$RPC_PORT"
RPC_URL["m"]="http://127.0.0.1:$RPC_PORT"
declare -A NODE_NAME NODE_CLUSTER NODE_VOTE NODE_IP NODE_BALANCE_WARN NODE_ENABLED
NODE_NAME["AAA"]="TestNode"
NODE_CLUSTER["AAA"]="t"
NODE_VOTE["AAA"]="VOTEAAA"
NODE_IP["AAA"]=""
NODE_BALANCE_WARN["AAA"]=1
NODE_ENABLED["AAA"]=1
CHECK_INTERVAL=1
DELINQUENT_SLOT_DISTANCE=20
ALERT_THRESHOLD=1
ALERT_REPEAT_INTERVAL=300
PING_INTERVAL=60
PING_COUNT=1
PING_TIMEOUT=1
PING_DEADLINE=3
BALANCE_INTERVAL=600
BALANCE_REPEAT_INTERVAL=3600
SUMMARY_INTERVAL=3600
SKIP_DOP=15
DAILY_INFO_HOUR=99
HEARTBEAT_HOUR=-1
SFDP_ENABLED=1
CONNECT_TIMEOUT=2
RPC_TIMEOUT=3
CLI_TIMEOUT=10
TG_TIMEOUT=2
ALARM_RETRIES=1
ALARM_RETRY_DELAY=1
TG_SEND_GAP=0
LOG_MAX_KB=1024
BOT_DIR="$WORK"
STATE_DIR="\$BOT_DIR/state"
LOG_FILE="\$BOT_DIR/bot.log"
LOCK_FILE="\$STATE_DIR/bot.lock"
CFG

date +%s > "$WORK/state/mark_summary"   # dashboard already "sent"

OK='{"jsonrpc":"2.0","id":1,"result":{"current":[{"votePubkey":"VOTEAAA","activatedStake":1}],"delinquent":[]}}'
DELINQ='{"jsonrpc":"2.0","id":1,"result":{"current":[],"delinquent":[{"votePubkey":"VOTEAAA","activatedStake":1}]}}'
VANISHED='{"jsonrpc":"2.0","id":1,"result":{"current":[],"delinquent":[]}}'
RPCERR='{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad params"}}'

# Run one cycle, print only what would have been sent.
run() {
    echo "$1" > "$WORK/rpc_reply"
    TG_DRYRUN=1 ONE_SHOT=1 bash "$WORK/bot.sh" 2>&1 \
        | grep -o 'DRYRUN -> \[.*\] .*' | sed 's/DRYRUN -> \[[^]]*\] //'
}
run_full() {   # whole output, for multi-line messages
    TG_DRYRUN=1 ONE_SHOT=1 bash "$WORK/bot.sh" 2>&1
}

pass=0; fail=0
expect()    { if grep -qF -- "$2" <<< "$3"; then echo "  ok   $1"; pass=$((pass+1));
              else echo "  FAIL $1 — '$2' not found in: ${3:-<empty>}"; fail=$((fail+1)); fi; }
expect_no() { if grep -qF -- "$2" <<< "$3"; then echo "  FAIL $1 — '$2' should not be there"; fail=$((fail+1));
              else echo "  ok   $1"; pass=$((pass+1)); fi; }

echo "1. healthy node stays silent"
out=$(run "$OK")
expect_no "no messages" "TestNode" "$out"

echo ""
echo "2. delinquent -> alarm"
out=$(run "$DELINQ")
expect "delinquency alarm" "TestNode — delinquent!" "$out"

echo ""
echo "3. node vanishes after the alarm (regression: used to report recovery)"
out=$(run "$VANISHED")
expect    "gone alarm"           "TestNode — gone from the validator list!" "$out"
expect_no "no false back online" "TestNode — back online!"                  "$out"

echo ""
echo "4. back in the list, still delinquent"
out=$(run "$DELINQ")
expect "back in list" "TestNode — back in the validator list (still delinquent)" "$out"

echo ""
echo "5. recovered -> all clear"
out=$(run "$OK")
expect "recovery" "TestNode — back online!" "$out"

echo ""
echo "6. rpc error -> silence, not a guess"
out=$(run "$RPCERR")
expect_no "nothing invented" "TestNode" "$out"

echo ""
echo "7. garbage instead of json -> silence"
out=$(run "not json at all")
expect_no "nothing invented" "TestNode" "$out"

echo ""
echo "8. the fast loop never calls the solana CLI"
expect "no CLI calls" "0" "$(wc -l < "$WORK/cli_calls.log" | tr -d ' ')"

echo ""
echo "9. one fast cycle = exactly one getVoteAccounts per node"
: > "$WORK/rpc_calls.log"
out=$(run "$OK")
expect "single call" "1" "$(grep -c getVoteAccounts "$WORK/rpc_calls.log" || true)"

echo ""
echo "10. empty NODE_VOTE is fatal"
sed -i.bak 's/NODE_VOTE\["AAA"\]="VOTEAAA"/NODE_VOTE["AAA"]=""/' "$WORK/config.sh"
echo "$OK" > "$WORK/rpc_reply"
out=$(run_full)
expect "caught"        "NODE_VOTE is required"       "$out"
expect "refused start" "FATAL: config.sh has errors" "$out"
mv "$WORK/config.sh.bak" "$WORK/config.sh"

echo ""
echo "11. bad NODE_CLUSTER is fatal"
sed -i.bak 's/NODE_CLUSTER\["AAA"\]="t"/NODE_CLUSTER["AAA"]="x"/' "$WORK/config.sh"
out=$(run_full)
expect "caught" "NODE_CLUSTER must be 't' or 'm'" "$out"
mv "$WORK/config.sh.bak" "$WORK/config.sh"

echo ""
echo "12. hourly dashboard: built from the cache, no gossip/stakes"
cat > "$WORK/fake_validators.json" <<'JSON'
{"validators":[{"identityPubkey":"AAA","delinquent":false,"version":"2.2.16","epochCredits":250,"activatedStake":58000000000},{"identityPubkey":"TOP","delinquent":false,"version":"2.3.0","epochCredits":500,"activatedStake":9000000000}],"averageStakeWeightedSkipRate":4.20}
JSON
rm -f "$WORK/state/mark_summary"
: > "$WORK/cli_calls.log"
echo "$OK" > "$WORK/rpc_reply"
out=$(run_full)
expect    "dashboard sent"        "TestNode"              "$out"
expect    "active stake"          "active_stk >>>[58.00]" "$out"
expect    "rank by credits"       "rank>[2]"              "$out"
expect_no "activating not hourly" "activating"            "$out"
expect    "validators pulled"     "validators"            "$(cat "$WORK/cli_calls.log")"
expect_no "gossip not called"     "gossip"                "$(cat "$WORK/cli_calls.log")"
expect_no "stakes not hourly"     "stakes"                "$(cat "$WORK/cli_calls.log")"
date +%s > "$WORK/state/mark_summary"

echo ""
echo "13. epoch info from getEpochInfo, reward from getInflationReward"
rm -f "$WORK/state/mark_summary"
: > "$WORK/cli_calls.log"
cat > "$WORK/reply_getEpochInfo" <<'JSON'
{"jsonrpc":"2.0","id":1,"result":{"epoch":42,"slotIndex":216000,"slotsInEpoch":432000}}
JSON
cat > "$WORK/reply_getInflationReward" <<'JSON'
{"jsonrpc":"2.0","id":1,"result":[{"epoch":41,"amount":1234000000,"commission":5}]}
JSON
echo "$OK" > "$WORK/rpc_reply"
out=$(run_full)
expect    "epoch number"        "[42]"                   "$out"
expect    "percent"             "[50.0%]"                "$out"
expect    "eta (216000 slots x 0.4s = a day)" "Ends in: ~1d 0h 0m" "$out"
expect    "real reward"         "commission>[1.23 sol | ep 41]"   "$out"
expect_no "epoch-info CLI unused" "epoch-info"           "$(cat "$WORK/cli_calls.log")"
date +%s > "$WORK/state/mark_summary"

echo ""
echo "14. no reward yet -> n/a, not a made-up number"
rm -f "$WORK/state/mark_summary"
echo '{"jsonrpc":"2.0","id":1,"result":[null]}' > "$WORK/reply_getInflationReward"
out=$(run_full)
expect "honest n/a" "commission>[n/a]" "$out"
rm -f "$WORK/reply_getEpochInfo" "$WORK/reply_getInflationReward"
date +%s > "$WORK/state/mark_summary"

echo ""
echo "15. a node name with & and < does not break the HTML"
rm -f "$WORK/state/mark_summary"
sed -i.bak 's|NODE_NAME\["AAA"\]="TestNode"|NODE_NAME["AAA"]="Bob \& <b>Node</b>"|' "$WORK/config.sh"
echo "$OK" > "$WORK/rpc_reply"
out=$(run_full)
expect    "ampersand escaped" "&amp;"        "$out"
expect    "tag defused"       "&lt;b&gt;"    "$out"
expect_no "raw tag blocked"   "<b>Bob & <b>" "$out"
mv "$WORK/config.sh.bak" "$WORK/config.sh"
date +%s > "$WORK/state/mark_summary"

echo ""
echo "16. SFDP_ENABLED=0 skips api.solana.org"
rm -f "$WORK/state/mark_summary"
echo 'SFDP_ENABLED=0' >> "$WORK/config.sh"
out=$(run_full)
expect_no "no onboard line" "onboard" "$out"
sed -i.bak '/^SFDP_ENABLED=0$/d' "$WORK/config.sh"
date +%s > "$WORK/state/mark_summary"

echo ""
echo "17. the loop sleeps the remainder, so the period holds"
sed -i.bak 's/^CHECK_INTERVAL=1$/CHECK_INTERVAL=3/' "$WORK/config.sh"
echo "$OK" > "$WORK/rpc_reply"
: > "$WORK/rpc_calls.log"
TG_DRYRUN=1 bash "$WORK/bot.sh" >/dev/null 2>&1 &
BOT_PID=$!
sleep 7.5
kill -TERM $BOT_PID 2>/dev/null; wait $BOT_PID 2>/dev/null
cycles=$(grep -c getVoteAccounts "$WORK/rpc_calls.log" || true)
if (( cycles >= 2 && cycles <= 4 )); then
    echo "  ok   ~7.5s at a 3s interval ran $cycles cycles"
    pass=$((pass+1))
else
    echo "  FAIL period drifted: $cycles cycles in 7.5s at a 3s interval"
    fail=$((fail+1))
fi

echo ""
echo "integration: passed $pass, failed $fail"
(( fail == 0 ))
