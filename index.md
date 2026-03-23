# IdleCore — Documentation

> Framework version: 1.0 · Luau (strict-mode compatible) · Roblox Studio

Welcome to the IdleCore documentation. Use the links below to navigate each section.

---

## Contents

| Section | Description |
|---------|-------------|
| [Quick Start](./quick-start.md) | From zero to a running game in ~20 lines |
| [Folder Structure](./folder-structure.md) | Where every file lives and why |
| [Service Dependency Map](./dependency-map.md) | How services relate and what is intentionally decoupled |
| [Data Schema](./data-schema.md) | Save document layout, defaults, and an example |
| [TickService](./services/tick-service.md) | Central heartbeat — API, groups, and usage |
| [CurrencyService](./services/currency-service.md) | Wallets, passive income, multipliers — API and remotes |
| [UpgradeService](./services/upgrade-service.md) | Tiered upgrades, cost scaling, effect callbacks |
| [PrestigeService](./services/prestige-service.md) | Reset lifecycle, carry-overs, points formula |
| [SaveService](./services/save-service.md) | DataStore persistence, migrations, shutdown flush |
| [UIService](./services/ui-service.md) | Reactive labels, animated counters, upgrade buttons |
| [Config Reference](./config-reference.md) | Every field in every Config file |
| [Remotes Reference](./remotes-reference.md) | All RemoteEvents and RemoteFunctions |
| [Migration Guide](./migration-guide.md) | Adding schema migrations safely |
| [Common Patterns](./common-patterns.md) | Passive income, prestige reset order, admin commands |
| [Changelog](./changelog.md) | Version history |

---

## At a Glance

```
TickService          heartbeat primitive — drives income ticks and auto-save
CurrencyService      server-authoritative wallets with passive income
UpgradeService       tiered upgrades with exponential cost scaling
PrestigeService      full reset lifecycle with multipliers and carry-overs
SaveService          DataStore persistence with versioned migrations
UIService            reactive client-side displays and animated counters
```

All services are wired together in `ServerMain` and `ClientMain`. No service directly `require()`s another except through explicit constructor injection — the decoupling is intentional and documented in [Service Dependency Map](./dependency-map.md).

---

*IdleCore is MIT licensed. See [LICENSE](../LICENSE) for details.*
