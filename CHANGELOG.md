## 2.1.3

- Made `bootstrap.sh` fall back to GitHub source archives when release assets are missing and locate the installer within extracted directories.
- Documented the fallback behaviour in the README quick-install section.

## 2.1.2

- Added Telegram bot bridge with authenticated command support and documented setup in the README.
- Reworked `generate.sh` to package the tracked tree (including the Makefile) without hard-coded router IPs.
- Created an OpenWrt SDK `Makefile` and GitHub Actions workflow to publish build artifacts automatically.

## 2.1.1

- Hardened `generate.sh` with dependency checks, safer path handling, and shared installer sourcing.
- Reworked `install.sh` to validate prerequisites, manage services idempotently, and restart the UI cleanly.
- Added `bootstrap.sh` for one-line installs from GitHub and documented the workflow in the README.

## 2.1.0

- Web UI: per-group filter, dark mode, live refresh, action buttons (Pause 30m, Block, Unblock), basic usage graph from AdGuard querylog.
- RPCD: structured `get_overview`, parsed `health`, new methods: `pause_client`, `block_client`, `unblock_client`, `adguard_querylog`.
- Scheduler: multi-schedule support per group, pause handling, daily quota minutes using nft counters (approximate active minutes).
- Nft apply: idempotent setup of parental table, blocked set, usage chain, per-client counters, and jump from `fw4`.
- Health: richer JSON fields (uptime, nft, fw4 chain rule, cron, AdGuard status).

## 2.0.0

- Initial Parental Suite v2.

