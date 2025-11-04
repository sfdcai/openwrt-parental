## 2.1.0

- Web UI: per-group filter, dark mode, live refresh, action buttons (Pause 30m, Block, Unblock), basic usage graph from AdGuard querylog.
- RPCD: structured `get_overview`, parsed `health`, new methods: `pause_client`, `block_client`, `unblock_client`, `adguard_querylog`.
- Scheduler: multi-schedule support per group, pause handling, daily quota minutes using nft counters (approximate active minutes).
- Nft apply: idempotent setup of parental table, blocked set, usage chain, per-client counters, and jump from `fw4`.
- Health: richer JSON fields (uptime, nft, fw4 chain rule, cron, AdGuard status).

## 2.0.0

- Initial Parental Suite v2.

