# MyLoop 🌍⬡

**Real-world territory capture.** Walk a closed loop outdoors → claim every H3 hexagon
inside it. Defend your turf, steal from rivals, climb your city's leaderboard — with
live map updates and push notifications.

> Pokémon GO meets Risk meets Strava — but you're conquering real geographic territory.

**Status:** closed beta · Flutter mobile client + .NET 10 REST API · Neon Postgres · Firebase auth

---

## How it works

```
1. Open the app  → see the hex map with everyone's territory
2. START JOURNEY → walk outside; GPS traces your path
3. STOP & CAPTURE → the server validates the walk (anti-cheat)
4. Every hex inside your loop becomes yours (colored on the map)
5. Rivals get a push: "Your territory was stolen!" → they walk back to reclaim
```

You *see* your territory, others can *steal* it, you're *notified* instantly, you *walk back*
to defend. Repeat.

---

## Repository layout

This is a monorepo. Each top-level directory owns one concern.

| Path | What lives here |
|------|-----------------|
| `api/MyLoop.Api/` | .NET 10 REST API — Controllers → Services → EF Core, SignalR `Hubs/`, `Migrations/` |
| `mobile/` | Flutter app (Riverpod, go_router, Dio) — see [`mobile/README.md`](mobile/README.md) |
| `tests/` | Backend test suite (xUnit, Testcontainers Postgres) |
| `scripts/` | Dev/utility scripts |
| `docs/` | **Canonical knowledge base** — architecture, ADRs, runbooks, compliance, product spec |
| `.claude/skills/` | Repo-vendored review/standards skills (see `CLAUDE.md`) |

Full component map, endpoint reference, and SignalR contract:
**[`docs/architecture/frontend-backend-reference.md`](docs/architecture/frontend-backend-reference.md)**.

---

## Architecture at a glance

```
┌─────────────────────────────────────────────────────────┐
│  MOBILE (Flutter / Riverpod)                            │
│  ┌──────────┐  ┌───────────┐  ┌──────────────────────┐  │
│  │ GPS      │  │ Map       │  │ SignalR client        │  │
│  │ tracking │  │ rendering │  │ (region subscription) │  │
│  └────┬─────┘  └─────┬─────┘  └──────────┬───────────┘  │
│       └──────────────┼───────────────────┘              │
│                      ▼  API Service (Dio + JWT)         │
└──────────────────────┼──────────────────────────────────┘
                       │ HTTPS + WebSocket (wss)
┌──────────────────────┼──────────────────────────────────┐
│  BACKEND (.NET 10)   ▼                                   │
│   Controllers (thin) → Services → EF Core → Postgres     │
│   SignalR Hub (region groups)      FCM push service      │
└──────────────────────┬──────────────────────────────────┘
                       ▼  Neon serverless Postgres (H3 hex ownership)
```

| Concern | Technology |
|---------|-----------|
| Mobile | Flutter / Dart, Riverpod (state), go_router (nav), Dio (HTTP) |
| Backend | .NET 10 / ASP.NET Core, EF Core, SignalR |
| Database | Neon (serverless PostgreSQL) |
| Spatial grid | H3 (Uber) — uniform global hexagons, polygon fill, hierarchy |
| Auth | Firebase Authentication (Google + Apple), JWT validated on every request |
| Push | Firebase Cloud Messaging |

The end-to-end claim pipeline, spatial model, and real-time contract each have a dedicated
page under [`docs/architecture/`](docs/architecture/).

---

## Running locally

### Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com)
- [Flutter SDK](https://flutter.dev)
- A PostgreSQL connection string (this project uses [Neon](https://neon.tech); any Postgres works)
- Firebase config: `google-services.json` (Android) / `GoogleService-Info.plist` (iOS) — **not committed**

### API

Configuration is supplied via .NET user-secrets (never committed). At minimum, set the
database connection string:

```bash
cd api/MyLoop.Api
dotnet user-secrets set "ConnectionStrings:DefaultConnection" \
  "Host=<neon-host>;Database=<db>;Username=<user>;Password=<pw>;SSL Mode=Require;Timeout=30"

dotnet run --launch-profile http     # → http://localhost:5048
```

On first run the API applies its schema (`EnsureCreated` + `DbInitializer`) and seeds bot
territory. SignalR hub is at `/hubs/territory`.

> Neon scales to zero when idle; the first request after a cold start may retry transparently
> (the DbContext uses `EnableRetryOnFailure`). Use `Timeout=` (Npgsql), not `Connection Timeout=`.

### Mobile

```bash
cd mobile
flutter pub get
flutter run
```

### Exposing the local API to a device (ngrok)

The mobile client targets a stable public URL for the local API. Start a tunnel on your
reserved domain so the existing build reaches it unchanged:

```bash
ngrok config add-authtoken <YOUR_TOKEN>
ngrok http 5048 --url=https://<your-reserved-domain>.ngrok-free.dev
```

The API is JWT-gated, but a public tunnel exposes it to the internet — stop ngrok when done.

---

## Testing

| Command | Scope |
|---------|-------|
| `dotnet test` (from `tests/`) | Backend unit + integration (integration tests need Docker for Testcontainers → run in CI) |
| `flutter test` (from `mobile/`) | Widget + service tests |
| `flutter analyze` (from `mobile/`) | Static analysis / lints |

CI runs .NET build+test and Flutter analysis on every PR; PRs must be green to merge.

---

## Documentation

Everything versions in-repo under [`docs/`](docs/) — no external wiki. Start at
[`docs/README.md`](docs/README.md).

| Area | Location |
|------|----------|
| System architecture & API/SignalR contract | [`docs/architecture/`](docs/architecture/) |
| Architectural Decision Records (ADRs) | [`docs/decisions/`](docs/decisions/) |
| Operational runbooks | [`docs/runbooks/`](docs/runbooks/) |
| App Store / privacy / data-deletion compliance | [`docs/compliance/`](docs/compliance/) |
| Product & technical spec | [`docs/product/spec.md`](docs/product/spec.md) |
| Game-design rationale | [`docs/product/design-log.md`](docs/product/design-log.md) |
| Phase learnings | [`docs/learnings/`](docs/learnings/) |

Game rules and tunable values (cooldowns, distances, limits, tiers) are defined in
`api/MyLoop.Api/Constants/` — treat that code as the source of truth over any prose.

---

## Contributing

- **Agent instructions:** `CLAUDE.md` is the canonical guide (conduct rules, the Socratic
  Requirement & Design Protocol, and the Pre-Check-in / Pre-PR skill gates). The `.clinerules`,
  `.cursorrules`, and `.github/copilot-instructions.md` files are **generated by an external
  knowledge-kit and gitignored** — do not hand-edit them.
- **Branches:** `{username}/{short-description}`. Never push directly to `master` (protected).
- **PRs:** one concern per PR; describe the *why*; ≥1 approval + green CI required to merge.
  Run the relevant Pre-PR skills and note them in the PR description.

---

## License

Private repository. All rights reserved.
