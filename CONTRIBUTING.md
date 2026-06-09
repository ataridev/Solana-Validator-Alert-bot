# Contributing

Thanks for your interest in improving Solana Validator Alert Bot!

## Ground rules

- **Never commit secrets.** `secrets.env`, `state/`, and `bot.log` are
  gitignored — keep it that way.
- **Keep it dependency-light.** The project targets a cheap VPS: Bash + `curl`,
  `jq`, `bc`, `ping`, and the `solana` CLI. Avoid adding new runtime deps.
- **Lint your shell.** Run `shellcheck` locally before opening a PR:
  ```bash
  shellcheck bot.sh install.sh lib/*.sh
  ```
  CI runs ShellCheck on every push/PR.

## Development

```bash
git clone <your-fork> && cd Solana-Validator-Alert-bot
cp secrets.env.example secrets.env   # fill in test bot token + chat ids
./bot.sh                              # run in the foreground
```

## Pull requests

- One focused change per PR.
- Update `README.md` / `config.sh` comments if behavior or options change.
- Describe how you tested (e.g. simulated delinquency, low balance, restart).
