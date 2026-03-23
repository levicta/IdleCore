# Changelog

All notable changes to IdleCore will be documented here.

This project follows [Semantic Versioning](https://semver.org/).

---

## [1.0.0] — 2025

### Added
- `TickService` — frame-rate-independent heartbeat with named groups, per-callback `pcall` isolation, and graceful hitch handling
- `CurrencyService` — server-authoritative multi-currency wallet with passive income, per-player multipliers, and dirty-state notification
- `UpgradeService` — tiered upgrade system with exponential cost scaling, prerequisites, effect callbacks, and in-flight purchase guard
- `PrestigeService` — full prestige lifecycle with carry-over snapshot, points formula, compounding multipliers, and decoupled reset callbacks
- `SaveService` — DataStore persistence with schema versioning, automatic migrations, dirty-flag writes, exponential backoff, and `BindToClose` flush
- `UIService` — reactive client displays, frame-driven animated number counters, and auto-managed upgrade buttons
- `ServerMain` / `ClientMain` bootstrap scripts wiring all services in correct dependency order
- Full `CurrencyConfig`, `UpgradeConfig`, `PrestigeConfig`, `SaveConfig`, `UIConfig` — all game-tunable without touching service code
- `CurrencyRemotes`, `UpgradeRemotes`, `PrestigeRemotes` — single-source-of-truth remote definitions shared by server and client

---

## Roadmap

- [ ] `RebirthService` — second prestige layer built on top of `PrestigeService`
- [ ] BigNum module — arbitrary-precision number support for values beyond `1e300`
- [ ] `AdminService` — UserId-allowlisted server commands for moderation
- [ ] Unit test suite (`TestEZ` / `Jest-Lua`) covering purchase atomicity and migration chains
- [ ] Rojo project file for source-control-friendly Studio workflow
