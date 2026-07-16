#!/bin/bash
# ============================================================================
#  Solana Validator Bot — configuration
#  Keep secrets (token, chat ids) in secrets.env — it is excluded from git.
# ============================================================================

# --- Path to the solana binary ---------------------------------------------
# NOTE: keep the word "solana" in the path.
SOLANA_PATH="$HOME/.local/share/solana/install/active_release/bin/solana"

# --- RPC endpoints per cluster ---------------------------------------------
# Key is the cluster code: t = testnet, m = mainnet-beta.
declare -A RPC_URL
RPC_URL["t"]="https://api.testnet.solana.com"
RPC_URL["m"]="https://api.mainnet-beta.solana.com"

# ============================================================================
#  NODE LIST
#  One entry per node, the array key is the Identity pubkey.
#  testnet and mainnet nodes can be mixed in the same file.
#  To add a node, copy a block and change the IDENTITY/values.
# ============================================================================
declare -A NODE_NAME          # display name
declare -A NODE_CLUSTER       # t (testnet) or m (mainnet)
declare -A NODE_VOTE          # vote account pubkey (required — delinquency is checked by it)
declare -A NODE_IP            # server IP for the ping check (can be left "")
declare -A NODE_BALANCE_WARN  # identity balance threshold in SOL for an alarm
declare -A NODE_ENABLED       # 1 — monitor, 0 — disabled

# --- Node 1 -----------------------------------------------------------------
NODE_NAME["IDENTITY1"]="MyNode TestNet"
NODE_CLUSTER["IDENTITY1"]="t"
NODE_VOTE["IDENTITY1"]="VOTE1"
NODE_IP["IDENTITY1"]="1.2.3.4"
NODE_BALANCE_WARN["IDENTITY1"]=1
NODE_ENABLED["IDENTITY1"]=1

# --- Node 2 (mainnet example, disabled) ------------------------------------
# NODE_NAME["IDENTITY2"]="MyNode MainNet"
# NODE_CLUSTER["IDENTITY2"]="m"
# NODE_VOTE["IDENTITY2"]="VOTE2"
# NODE_IP["IDENTITY2"]="5.6.7.8"
# NODE_BALANCE_WARN["IDENTITY2"]=1
# NODE_ENABLED["IDENTITY2"]=0

# ============================================================================
#  MONITORING PARAMETERS
# ============================================================================

# --- Fast loop: delinquency only -------------------------------------------
CHECK_INTERVAL=10            # how often to poll delinquency, seconds
DELINQUENT_SLOT_DISTANCE=20  # slot distance after which a node is delinquent
ALERT_THRESHOLD=3            # consecutive confirmations before the first alarm (anti false-positive)
ALERT_REPEAT_INTERVAL=300    # repeat "still delinquent", seconds (anti-spam)

# --- Medium loop: ping ------------------------------------------------------
PING_INTERVAL=60             # how often to ping the server, seconds
PING_COUNT=2                 # number of ping packets to send
PING_TIMEOUT=1               # wait per packet, seconds (-W)
PING_DEADLINE=3              # hard limit for the whole ping run, seconds (-w)

# --- Balance ----------------------------------------------------------------
# Separate from the ping cadence: an identity balance drains over hours, so
# polling it every minute is ~1300 pointless RPC calls a day.
BALANCE_INTERVAL=600         # how often to check the identity balance, seconds
BALANCE_REPEAT_INTERVAL=3600 # repeat balance alarm, seconds

# --- Skip rate alarm --------------------------------------------------------
# The dashboard has always shown the skip rate, but only once an hour and only
# if someone reads it. This alarms on it instead.
SKIP_ALERT_ENABLED=1
SKIP_CHECK_INTERVAL=600      # how often to check the skip rate, seconds
SKIP_ALERT_THRESHOLD=30      # skip % that raises an alarm
SKIP_ALERT_MIN_SLOTS=20      # ignore below this many leader slots — early in an
                             # epoch a couple of slots make the % meaningless
SKIP_REPEAT_INTERVAL=3600    # repeat the skip alarm, seconds

# --- Version alarm ----------------------------------------------------------
# Compares against the version running the most stake in the cluster, checked
# once an hour together with the dashboard refresh.
VERSION_ALERT_ENABLED=1
VERSION_ALERT_THRESHOLD=2    # consecutive hourly checks before alarming
VERSION_REPEAT_INTERVAL=86400 # repeat, seconds (a version lag is not urgent)

# --- Dashboard summary (rich info to the info chat) ------------------------
SUMMARY_INTERVAL=3600        # how often to send the full summary, seconds (3600 = hourly)
SKIP_DOP=15                  # margin over the cluster average skip for 🟢/🔴

# --- Daily info (SFDP/KYC status + epoch) ----------------------------------
DAILY_INFO_HOUR=15           # hour (server time, see `date`) for the daily summary

# Set to 0 if the validator is not in the Solana Foundation Delegation Program:
# skips the daily api.solana.org lookups and the testnet onboarding line.
SFDP_ENABLED=1

# --- Bot heartbeat ----------------------------------------------------------
HEARTBEAT_HOUR=9             # hour for the "bot alive" message (-1 = disable)

# ============================================================================
#  NETWORK TIMEOUTS
#  Without these a hung endpoint silently stops the monitoring: the bot keeps
#  running but never completes a cycle, which looks exactly like "all is well".
# ============================================================================
CONNECT_TIMEOUT=5            # TCP connect timeout for any HTTP call, seconds
RPC_TIMEOUT=15               # total timeout for one RPC/HTTP call, seconds
CLI_TIMEOUT=60               # hard limit for one `solana` CLI call, seconds
TG_TIMEOUT=15                # total timeout for one Telegram API call, seconds

# --- Alarm delivery ---------------------------------------------------------
ALARM_RETRIES=3              # delivery attempts per alarm (info messages: 1)
ALARM_RETRY_DELAY=2          # base backoff between attempts, seconds (doubles)
# Telegram rate-limits a chat at roughly 20 messages/minute, and the hourly
# report fires one per node plus one per cluster back to back.
TG_SEND_GAP=0.4              # pause after each sent message, seconds

# --- Logging ----------------------------------------------------------------
# Under systemd stdout already goes to the journal, so bot.log is only written
# on manual runs. This caps it there.
LOG_MAX_KB=5120              # rotate bot.log past this size (to bot.log.1)

# ============================================================================
#  Internal paths (usually no need to change)
# ============================================================================
BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$BOT_DIR/state"
LOG_FILE="$BOT_DIR/bot.log"
LOCK_FILE="$STATE_DIR/bot.lock"
