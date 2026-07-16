#!/bin/bash
# ============================================================================
#  Unit tests for the library functions.
#  No network: rpc_call is replaced with a stub that echoes a canned reply.
#  Run: tests/unit.sh   (or tests/run.sh for everything)
# ============================================================================
set -uo pipefail

BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR=$(mktemp -d)
LOG_FILE="$STATE_DIR/test.log"
trap 'rm -rf "$STATE_DIR"' EXIT

log_message() { :; }

# Config values the functions under test read.
ALERT_THRESHOLD=3
ALERT_REPEAT_INTERVAL=300
CONNECT_TIMEOUT=5
RPC_TIMEOUT=15
CLI_TIMEOUT=60
DELINQUENT_SLOT_DISTANCE=20
SOLANA_PATH=/bin/echo
declare -A RPC_URL=([t]="http://127.0.0.1:1" [m]="http://127.0.0.1:1")

# shellcheck source=../lib/state.sh
source "$BOT_DIR/lib/state.sh"
# shellcheck source=../lib/solana.sh
source "$BOT_DIR/lib/solana.sh"
# shellcheck source=../lib/telegram.sh
source "$BOT_DIR/lib/telegram.sh"

pass=0; fail=0
check() {
    if [[ "$2" == "$3" ]]; then
        echo "  ok   $1"
        pass=$(( pass + 1 ))
    else
        echo "  FAIL $1 — expected '$2', got '$3'"
        fail=$(( fail + 1 ))
    fi
}

# --- vote_status ------------------------------------------------------------
echo "vote_status: node health from getVoteAccounts"
FAKE_REPLY=""
rpc_call() { echo "$FAKE_REPLY"; }
vs() { FAKE_REPLY="$1"; vote_status t VOTEAAA; }

check "voting -> ok" "ok" \
  "$(vs '{"result":{"current":[{"votePubkey":"VOTEAAA"}],"delinquent":[]}}')"
check "behind -> delinquent" "delinquent" \
  "$(vs '{"result":{"current":[],"delinquent":[{"votePubkey":"VOTEAAA"}]}}')"
check "in neither list -> not_found" "not_found" \
  "$(vs '{"result":{"current":[],"delinquent":[]}}')"
check "rpc error -> unknown" "unknown" \
  "$(vs '{"error":{"code":-32602,"message":"bad params"}}')"
check "garbage -> unknown" "unknown" "$(vs 'not json at all')"
check "empty response -> unknown" "unknown" "$(vs '')"

# --- node_facts -------------------------------------------------------------
echo ""
echo "node_facts: one pass over the cached list"
cat > "$STATE_DIR/validators_t.json" <<'JSON'
{"validators":[
  {"identityPubkey":"TOP","delinquent":false,"version":"2.3.0","epochCredits":500,"activatedStake":9000000000},
  {"identityPubkey":"MID","delinquent":false,"version":"2.2.16","epochCredits":250,"activatedStake":58000000000},
  {"identityPubkey":"LOW","delinquent":true,"version":"2.2.16","epochCredits":100,"activatedStake":0}],
 "averageStakeWeightedSkipRate":4.2}
JSON

node_facts t MID
check "version"              "2.2.16"      "$NF_VERSION"
check "credits"              "250"         "$NF_CREDITS"
check "stake in lamports"    "58000000000" "$NF_STAKE"
check "rank by credits"      "2"           "$NF_RANK"
check "cluster top credits"  "500"         "$NF_TOP_CREDITS"
check "cluster average skip" "4.2"         "$NF_AVG_SKIP"

node_facts t TOP
check "leader ranks first"   "1"           "$NF_RANK"

if node_facts t NOSUCH; then r="0"; else r="1"; fi
check "absent node -> failure, not another node's data" "1" "$r"
check "no stale values left behind" "" "$NF_VERSION"

echo "not json" > "$STATE_DIR/validators_m.json"
if node_facts m MID; then r="0"; else r="1"; fi
check "broken cache -> failure" "1" "$r"

# Regression: a node with no version (absent from gossip) leaves an empty first
# field. With a tab separator bash collapses it and shifts stake into credits.
cat > "$STATE_DIR/validators_x.json" <<'JSON'
{"validators":[{"identityPubkey":"NOVER","delinquent":false,"epochCredits":250,"activatedStake":58000000000}],
 "averageStakeWeightedSkipRate":4.2}
JSON
node_facts x NOVER
check "no version -> field empty"      ""            "$NF_VERSION"
check "no version -> credits intact"   "250"         "$NF_CREDITS"
check "no version -> stake intact"     "58000000000" "$NF_STAKE"
check "no version -> rank intact"      "1"           "$NF_RANK"
check "no version -> skip intact"      "4.2"         "$NF_AVG_SKIP"

# --- version comparison -----------------------------------------------------
echo ""
echo "version_lt: numeric per component, tolerant of suffixes"
vlt() { if version_lt "$1" "$2"; then echo yes; else echo no; fi; }
check "2.2.16 < 2.3.0"      "yes" "$(vlt 2.2.16 2.3.0)"
check "2.3.0 not < 2.2.16"  "no"  "$(vlt 2.3.0 2.2.16)"
check "equal is not older"  "no"  "$(vlt 2.2.16 2.2.16)"
check "patch level counts"  "yes" "$(vlt 2.2.9 2.2.16)"   # not a string compare
check "major beats minor"   "yes" "$(vlt 1.18.23 2.0.0)"
check "suffix ignored"      "yes" "$(vlt 2.1.0-jito 2.2.0)"
check "suffix, same version" "no" "$(vlt 2.2.0-jito 2.2.0)"
check "short version"       "yes" "$(vlt 2.2 2.3.0)"

echo ""
echo "cluster_majority_version: weighted by stake, not by node count"
cat > "$STATE_DIR/validators_v.json" <<'JSON'
{"validators":[
  {"identityPubkey":"A","delinquent":false,"version":"2.3.0","activatedStake":100000},
  {"identityPubkey":"B","delinquent":false,"version":"2.2.16","activatedStake":10},
  {"identityPubkey":"C","delinquent":false,"version":"2.2.16","activatedStake":10},
  {"identityPubkey":"D","delinquent":false,"version":"2.2.16","activatedStake":10}],
 "averageStakeWeightedSkipRate":1}
JSON
check "three small nodes lose to one big one" "2.3.0" "$(cluster_majority_version v)"

cat > "$STATE_DIR/validators_w.json" <<'JSON'
{"validators":[
  {"identityPubkey":"A","delinquent":true,"version":"9.9.9","activatedStake":999999},
  {"identityPubkey":"B","delinquent":false,"version":"2.3.0","activatedStake":100}],
 "averageStakeWeightedSkipRate":1}
JSON
check "delinquent nodes excluded" "2.3.0" "$(cluster_majority_version w)"

# --- block_production -------------------------------------------------------
echo ""
echo "block_production: leader slots and produced blocks"
check "slots and produced" "32 30" \
  "$(FAKE_REPLY='{"result":{"value":{"byIdentity":{"AAA":[32,30]}}}}'; block_production t AAA)"
check "not leader yet -> empty" "" \
  "$(FAKE_REPLY='{"result":{"value":{"byIdentity":{}}}}'; block_production t AAA)"
check "rpc error -> empty" "" \
  "$(FAKE_REPLY='{"error":{"code":-32602,"message":"bad"}}'; block_production t AAA)"

# --- alarm_step custom pacing ----------------------------------------------
echo ""
echo "alarm_step: per-kind threshold and repeat interval"
alarm_step version N4 1 5000 2 86400; check "1st hourly check: silent" "none"  "$ALARM_DECISION"
alarm_step version N4 1 8600 2 86400; check "2nd check: own threshold" "first" "$ALARM_DECISION"
# an hour later: the default 300s repeat would re-alarm here, 86400 must not
alarm_step version N4 1 12200 2 86400; check "no hourly re-alarm" "none" "$ALARM_DECISION"
alarm_step version N4 1 95000 2 86400; check "repeats after a day" "repeat" "$ALARM_DECISION"

# --- inflation_reward -------------------------------------------------------
echo ""
echo "inflation_reward: the commission actually paid out"
check "reward present -> lamports" "1234000000" \
  "$(FAKE_REPLY='{"result":[{"epoch":811,"amount":1234000000,"commission":5}]}'; inflation_reward t VOTEAAA 811)"
check "no reward yet -> empty" "" \
  "$(FAKE_REPLY='{"result":[null]}'; inflation_reward t VOTEAAA 811)"
check "rpc error -> empty" "" \
  "$(FAKE_REPLY='{"error":{"code":-32602,"message":"bad"}}'; inflation_reward t VOTEAAA 811)"
check "current_epoch" "812" \
  "$(FAKE_REPLY='{"result":{"epoch":812,"slotIndex":1,"slotsInEpoch":432000}}'; current_epoch t)"

# --- lamports_to_sol --------------------------------------------------------
echo ""
echo "lamports_to_sol: keeps the leading zero bc drops"
check "whole"        "58.00" "$(lamports_to_sol 58000000000)"
check "below 1 SOL"  "0.50"  "$(lamports_to_sol 500000000)"
check "zero"         "0"     "$(lamports_to_sol 0)"

# --- alarm_step -------------------------------------------------------------
echo ""
echo "alarm_step: confirm -> alarm -> anti-spam -> repeat -> recover"
t=1000
alarm_step delinq N1 1 "$t";        check "1st hit: silent"        "none"    "$ALARM_DECISION"
alarm_step delinq N1 1 "$((t+10))"; check "2nd hit: silent"        "none"    "$ALARM_DECISION"
alarm_step delinq N1 1 "$((t+20))"; check "3rd hit: threshold"     "first"   "$ALARM_DECISION"
check "ST_COUNT available for the message" "3" "$ST_COUNT"
alarm_step delinq N1 1 "$((t+30))";  check "4th hit: anti-spam"    "none"    "$ALARM_DECISION"
alarm_step delinq N1 1 "$((t+319))"; check "before REPEAT: silent" "none"    "$ALARM_DECISION"
alarm_step delinq N1 1 "$((t+320))"; check "after REPEAT: repeat"  "repeat"  "$ALARM_DECISION"
alarm_step delinq N1 0 "$((t+400))"; check "problem gone: recover" "recover" "$ALARM_DECISION"
check "ST_START kept for the duration" "1000" "$ST_START"
alarm_step delinq N1 0 "$((t+500))"; check "already healthy: silent" "none"  "$ALARM_DECISION"

echo ""
echo "alarm_step: problem gone before the first alarm -> no recovery message"
alarm_step inet N2 1 2000; check "one hit, no alarm sent" "none" "$ALARM_DECISION"
alarm_step inet N2 0 2010; check "no false recovery"      "none" "$ALARM_DECISION"

echo ""
echo "alarm_step: kinds are independent"
alarm_step delinq N3 1 3000
alarm_step delinq N3 1 3010
alarm_step delinq N3 1 3020; check "delinq fired"          "first" "$ALARM_DECISION"
alarm_step gone   N3 1 3030; check "gone counts separately" "none" "$ALARM_DECISION"
check "delinq state untouched" "true" "$(state_active delinq N3 && echo true)"

# --- html_escape ------------------------------------------------------------
echo ""
echo "html_escape: a name with < or & must not break delivery"
check "ampersand"            "Bob &amp; Alice"        "$(html_escape 'Bob & Alice')"
check "angle brackets"       "&lt;node&gt;"           "$(html_escape '<node>')"
check "no double escaping"   "a &amp;lt; b"           "$(html_escape 'a &lt; b')"
check "plain name untouched" "MyNode MainNet"         "$(html_escape 'MyNode MainNet')"
check "injected tag defused" "&lt;b&gt;pwn&lt;/b&gt;" "$(html_escape '<b>pwn</b>')"

# --- marks ------------------------------------------------------------------
echo ""
echo "marks: loop timers survive a restart"
check "unset mark"     ""           "$(mark_get summary)"
mark_set summary 12345
check "reads back"     "12345"      "$(mark_get summary)"
mark_set daily "2026-07-16"
check "string mark"    "2026-07-16" "$(mark_get daily)"

echo ""
echo "unit: passed $pass, failed $fail"
(( fail == 0 ))
