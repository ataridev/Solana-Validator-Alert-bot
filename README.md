# 🛰️ Solana Validator Alert Bot

> Real-time Telegram alerting **and** a scheduled status report for Solana
> validators — in one tiny Bash daemon. Delinquency caught in seconds, full node
> status delivered on a schedule.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![ShellCheck](https://github.com/ataridev/Solana-Validator-Alert-bot/actions/workflows/shellcheck.yml/badge.svg)](../../actions)
![Bash](https://img.shields.io/badge/Bash-4%2B-1f425f.svg)
![Solana](https://img.shields.io/badge/Solana-validator%20ops-14F195.svg)

A single Bash daemon that watches one or more Solana validators and pushes
Telegram alerts the moment something goes wrong, plus a periodic status report.

## Overview

One daemon does both — a fast watchdog for instant alerts and a scheduled
status report for full visibility — with no heavyweight dependencies, so it runs
on the cheapest VPS.

## Features

- ⚡ **Fast delinquency detection** — continuous daemon, catches delinquency
  within seconds, with confirmation (anti false-positive), anti-spam, and
  recovery notifications.
- 📊 **Rich status report** — balance, stake (active/activating/deactivating),
  skip rate vs cluster average, credits, rank, commission, epoch, SFDP/KYC.
- 🌐 **Mixed clusters** — testnet and mainnet nodes in a single instance.
- 🚀 **Efficient** — one `solana validators` request per cluster per cycle
  (cached and reused for every node), not one request per node.
- 💾 **Persistent state** — survives a daemon restart; the bot remembers which
  nodes were delinquent.
- 💰 **Balance & connectivity alarms** — low identity balance and lost ping.

## Demo

**Alarm chat** (instant, with sound):

```
🚨 MyNode MainNet — delinquent! (confirmed over 3 checks)
❗ MyNode MainNet — still delinquent! (for 5 min)
✅ MyNode MainNet — back online! (was delinquent 12 min)
💰 MyNode MainNet — low identity balance: 0.42 SOL (threshold 1)
📡 MyNode MainNet — connectivity lost (ping 1.2.3.4 failing)!
```

**Info chat** (scheduled status report):

```
MyNode MainNet [Abcd123xyz] [2.2.16]
🌐 1.2.3.4
All:32 Done:18 skipped:1
skip:🟢5.55% Average:4.20%
credits >[412800] [98.50%]
rank>[123]
active_stk >>>[58000.00]
activating >>>[1500.00🟢]
deactivating >[0.00]
balance>[12.34]
vote_balance>>[3.50]
commission>[earn 1.234 sol]
```

## Architecture

A single daemon with several polling cadences:

- **Fast loop** (`CHECK_INTERVAL`, 10 s) — delinquency only. One `solana
  validators` call per cluster is cached and reused for all nodes. Skips a
  cluster whose data failed to refresh, so an RPC blip never triggers a false
  recovery.
- **Medium loop** (`PING_INTERVAL`, 60 s) — server ping and identity balance.
- **Summary** (`SUMMARY_INTERVAL`, 1 h) — full status report per node + epoch info.
- **Daily** (`DAILY_INFO_HOUR`) — SFDP and KYC status.
- **Heartbeat** (`HEARTBEAT_HOUR`) — "bot alive" message.

```
Solana-Validator-Alert-bot/
├── config.sh            # nodes (arrays keyed by pubkey) + all parameters
├── secrets.env(.example)# BOT_TOKEN, CHAT_ID_* — out of git
├── lib/
│   ├── telegram.sh      # delivery + throttling
│   ├── solana.sh        # CLI/RPC wrappers + per-cluster cache
│   └── state.sh         # persistent delinquency/alarm state
├── bot.sh               # daemon
├── install.sh           # one-command setup + systemd unit generator
└── solana-validator-alert-bot.service   # systemd unit template
```

## Quick start

```bash
git clone https://github.com/ataridev/Solana-Validator-Alert-bot.git
cd Solana-Validator-Alert-bot
./install.sh            # installs deps, scaffolds secrets.env, optional service
```

Then edit your config (see below) and start the bot.

> Requires the `solana` CLI (path is set in `config.sh` → `SOLANA_PATH`).

## Configuration

1. **Secrets.** Create a bot via [@BotFather](https://t.me/BotFather), two chats
   (alarms/info), and get their IDs via [@username_to_id_bot](https://t.me/username_to_id_bot).
   ```bash
   cp secrets.env.example secrets.env   # install.sh does this for you
   nano secrets.env   # BOT_TOKEN, CHAT_ID_ALARM, CHAT_ID_INFO
   ```
2. **Nodes.** In `config.sh` — one entry per node, the array key is the Identity
   pubkey. testnet (`t`) and mainnet (`m`) can be mixed:
   ```bash
   NODE_NAME["IDENTITY1"]="MyNode TestNet"
   NODE_CLUSTER["IDENTITY1"]="t"
   NODE_VOTE["IDENTITY1"]="VOTE1"
   NODE_IP["IDENTITY1"]="1.2.3.4"
   NODE_BALANCE_WARN["IDENTITY1"]=1
   NODE_ENABLED["IDENTITY1"]=1
   ```
3. **Parameters** (intervals, thresholds, summary hours) — also in `config.sh`.

## Run as a systemd service

`install.sh` can generate and enable the unit for you. To do it manually:

```bash
sudo cp solana-validator-alert-bot.service /etc/systemd/system/
# edit the paths/user inside the unit first
sudo systemctl daemon-reload
sudo systemctl enable --now solana-validator-alert-bot
sudo systemctl status solana-validator-alert-bot
journalctl -u solana-validator-alert-bot -f      # live logs
```

The service restarts automatically (`Restart=always`). Delinquency state is
stored in `state/` and survives a restart.

## Run manually

```bash
./bot.sh        # run in the current terminal, Ctrl+C to stop
tail -f bot.log
```

## Dependencies

`solana` CLI, `curl`, `jq`, `bc`, `ping`, `bash` (associative arrays → bash 4+).

## License

[MIT](LICENSE)
