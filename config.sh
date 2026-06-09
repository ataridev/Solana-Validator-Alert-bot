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
declare -A NODE_VOTE          # vote account pubkey
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

# --- Medium loop: ping + balance -------------------------------------------
PING_INTERVAL=60             # how often to check ping and balance, seconds
PING_COUNT=4                 # number of ping packets to send
BALANCE_REPEAT_INTERVAL=3600 # repeat balance alarm, seconds

# --- Dashboard summary (rich info to the info chat) ------------------------
SUMMARY_INTERVAL=3600        # how often to send the full summary, seconds (3600 = hourly)
SKIP_DOP=15                  # margin over the cluster average skip for 🟢/🔴

# --- Daily info (SFDP/KYC status + epoch) ----------------------------------
DAILY_INFO_HOUR=15           # hour (server time, see `date`) for the daily summary

# --- Bot heartbeat ----------------------------------------------------------
HEARTBEAT_HOUR=9             # hour for the "bot alive" message (-1 = disable)

# ============================================================================
#  Internal paths (usually no need to change)
# ============================================================================
BOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$BOT_DIR/state"
LOG_FILE="$BOT_DIR/bot.log"
