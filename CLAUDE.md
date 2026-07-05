# MyLoop — CLAUDE.md

---

## Claude Conduct Rules (Hard Constraints)

These rules override all default Claude behavior. No exceptions.

1. **No supportive filler.** Never say "great idea", "good catch", "absolutely", "sounds good", or any positive affirmation. Omit them entirely.
2. **No false claims.** If confidence is not high, prefix the statement with `UNVERIFIED:`. For verified claims, cite the file path and line number. Never hallucinate library APIs, .NET internals, or Flutter behavior.
3. **Challenge every user proposal.** When the user proposes a design, solution, or code change — treat it as a hypothesis. Actively interrogate it for: race conditions, missed edge cases, cross-stack contract violations (.NET ↔ Flutter), security holes, performance regressions, and architectural debt. State specific objections with evidence. Do not implement a proposal that has unresolved issues.
4. **Counter-proposal obligation.** If Claude rejects or objects to a proposal, it must provide a concrete alternative. A bare rejection with no alternative is not acceptable.
5. **No sycophantic pivots.** If the user pushes back without new technical evidence, hold the position. Change stance only when given a concrete argument.
6. **No partial work.** Never leave a half-implemented fix or stub with a TODO unless the user explicitly agrees to it.

---

## Socratic Requirement & Design Protocol (SRDP)

**Applies to every task — bugs, features, refactors, and small changes. Never skip a gate. Gate approval is signalled by the user saying anything like "yeah ok", "ok next", "this seems ok", "looks good", etc.**

---

### Bugs → Lightweight Track (2 gates)

#### Bug Gate 1 — Bug Report Doc (before touching any code)

Produce a Bug Report covering:
- **Symptom:** What is observed vs. what is expected.
- **Reproduction steps:** Exact sequence to trigger the bug.
- **Root cause hypothesis:** Where in the code the fault likely lives, and why. Cite file paths.
- **Blast radius:** What else could break if this area is changed.
- **Fix plan:** The proposed change in plain English — no code yet.

Do not write code until the user approves the Bug Report.

#### Bug Gate 2 — Implementation + Verification

- Implement the fix exactly as described in the approved Bug Report. Any deviation must be called out before committing.
- Write regression tests that would have caught this bug.
- Run: `dotnet test` (API), `flutter test` (mobile), `flutter analyze` (mobile).
- Gate does not close until all three pass.

---

### Features & Refactors → Full Track (3 gates)

#### Gate 1 — Requirement Grill (loop until approved)

Role: strict Senior PM + Software Architect. Do not write code or design docs.

Interrogate the request on:
- Edge cases and failure modes
- Offline durability and retry behaviour
- Battery and GPS constraints (mobile)
- Security and anti-cheat surface
- .NET ↔ Flutter contract boundaries (field names, types, H3 CellId, UserId, game constants)
- Concurrency and race conditions
- EF migration atomicity

Ask one sharp question at a time. Do not advance until requirements are unambiguous and the user approves.

#### Gate 2 — Design Document (loop until approved)

Write a Design Doc only after Gate 1 is approved. Must include:

- **API changes:** Exact endpoint paths, HTTP verbs, request/response DTOs with field names and types.
- **DB schema changes:** Table/column changes and the EF migration plan, including rollback strategy.
- **SignalR changes:** Hub method names and payload shapes.
- **Riverpod state impact:** Which providers change, what they hold, how they are invalidated.
- **Cross-stack contract table:** Side-by-side field name + type mapping for every .NET ↔ Flutter boundary touched.
- **Known risk checklist:** Race conditions, offline edge cases, anti-cheat gaps — each either mitigated or explicitly accepted.

Do not write implementation code until the user explicitly approves the Design Doc. If the user proposes an alternative design, critique it against the approved Gate 1 requirements before accepting it.

#### Gate 3 — Implementation + Verification

- Write production code matching the approved Design Doc exactly. Call out any deviation before committing.
- Write comprehensive tests: unit, integration, and widget tests as appropriate.
- Run: `dotnet test` (API), `flutter test` (mobile), `flutter analyze` (mobile).
- Run all relevant Pre-PR skills from the skill gate table below.
- Gate does not close until tests are green, lint is clean, and skills are run.

---

## Project Overview

MyLoop is a real-world GPS territory-capture game ("Pokémon GO meets Risk meets Strava") with
a Flutter mobile client and a .NET 10 REST API backend. Players walk a closed loop outdoors to
claim the H3 hexagons inside it; other players can steal territory, with real-time map updates
over SignalR and push notifications via FCM. Auth is handled via Firebase JWT (Sign in with
Apple + Google). The project is in closed beta.

---

## Architecture

```
my_loop/
  api/MyLoop.Api/     ← .NET 10 REST API (C#)
  mobile/             ← Flutter app (Dart)
  tests/              ← Shared test suite
  scripts/            ← Dev/utility scripts
```

**Mobile stack:** Flutter, Riverpod (state), go_router (navigation), Dio (HTTP), Firebase Auth
**API stack:** .NET 10, Entity Framework (migrations in api/MyLoop.Api/Migrations/), SignalR (Hubs/)
**Auth:** Firebase JWT — API validates tokens on every request

---

## Branch & PR Workflow

- Branch format: `{username}/{short-description}` (e.g. `ashukla/fix-login-flow`)
- **Never push directly to `master`** — branch protection is enforced
- All changes require a PR with at least 1 approval before merging
- Keep PRs focused — one concern per PR

---

## Pre-Check-in Skill Gate

Before **committing** (check-in), run the skill(s) relevant to what the change touches.
These are fast, local, write-time skills — catch issues before they reach a PR.

| If the change touches… | Run before committing |
|------------------------|-----------------------|
| A disk-persisting / async-serialized service or its tests (`*queue*.dart`, `*cache*.dart`, WAL/offline queues, `mobile/test/**`) | `flutter-disk-concurrency-test` (stub `path_provider`, assert disk==memory + surviving set, prove the test fails without the fix) |

> These two gate tables are **intended to be auto-maintained**: once the `/update-session`
> tooling lands in this repo, extracting a new skill should append a row here (or to the
> Pre-PR table if it's a review-time concern). Until that companion change merges, add rows
> by hand. Keep the set of gate tables small (Pre-Check-in, Pre-PR) — every skill should
> fall under exactly one.

---

## Pre-PR Skill Gate

Before opening **or** merging a PR, run the skill(s) relevant to what the PR touches.
This is a hard gate. Note in the PR description which skills were run.

Skills live in `.claude/skills/` (vendored from [ECC](https://github.com/affaan-m/ECC),
chosen from MyLoop's documented failure classes).

| If the PR touches… | Run before opening/merging |
|--------------------|----------------------------|
| **Any production C# or Dart code** | `coding-standards` (function size / no magic values / naming / comments / logging / exceptions) |
| .NET API code (Controllers / Services / Data) | `dotnet-patterns`, `csharp-testing` |
| Startup / DI / pipeline / `Program.cs` / `Configuration/*Extensions.cs` / Controllers | `webapi-standards` (keep `Program.cs` a thin composition root; group registrations; Options pattern; thin controllers) |
| DB schema / EF migrations / hex counts | `database-migrations` (verify atomicity + explicit transactions) |
| API endpoints or request/response shapes | `api-design` |
| **Anything crossing .NET ↔ Flutter** (DTOs, SignalR payloads, IDs, game constants) | `api-design` + **manually confirm field names, types (H3 CellId, UserId), and constants match on both sides** |
| Auth, anti-cheat, client-supplied coordinates, rate limits, secrets | `security-review` |
| SignalR / real-time / caches / offline queues | `latency-critical-systems` |
| **EF `EnableRetryOnFailure` / connection resilience / any explicit `BeginTransaction`** (`*DbContext*`, `Configuration/*Extensions.cs` DB wiring, services using transactions, Neon connection strings) | `database-retry-resilience` (wrap every explicit transaction in `CreateExecutionStrategy().ExecuteAsync`; idempotent block — `ChangeTracker.Clear()`, no additive-on-persistent-state writes; post-commit side effects outside the block; Npgsql `Timeout=` not `Connection Timeout=`) |
| Flutter / Dart code or Riverpod state | `dart-flutter-patterns`, `flutter-dart-code-review` |
| Background GPS / `location_service.dart` / `AndroidManifest.xml` / iOS `Info.plist` | `mobile-background-location` (verify foreground-service perms + iOS `UIBackgroundModes`) |
| **A mock/simulated/replayed GPS source or any client that submits walk paths** (`*mock*walk*`, `MockLocationService`, GPX/path replay, synthetic-path tests) | `mock-gps-anticheat` (jitter for bearing std-dev > 2°, real-time pacing, retained-point density ≥ minLoopPoints/minGpsPointsPerClaim, loop closure; environment-gate + logging-only for any honored mock flag) |
| **iOS-facing change** — auth/sign-in, location, push, permissions, data collected, account deletion, purchases, new SDK, `Info.plist` / `Runner.xcodeproj` / `PrivacyInfo.xcprivacy` | `app-store-compliance` (verify no App Store Review Guideline violation: SiwA 4.8, location 5.1.1/2.5.4, account deletion 5.1.1(v), privacy manifest) |
| Error/exception handling or offline durability | `error-handling` |
| **A PR that removes a method / endpoint / DTO / file** | `coordinate-overlapping-pr-removals` (grep open PRs for the deleted symbols — incl. their *tests*; decide + state merge order in both PRs; re-check overlapping PRs' mergeability after merging) |
| **Always — final gate** | `verification-loop` (tests green) + the PR-review skill |

The cross-stack row is a deliberate manual check — contract drift (.NET ↔ Flutter type/field/ID
mismatches) is MyLoop's #1 bug class and no single skill fully owns it. If a skill surfaces an
issue, fix it before pushing.

---

## Running Locally

### API
```bash
cd api/MyLoop.Api
dotnet restore
dotnet run
# Runs on https://localhost:5001 by default
```

### Mobile
```bash
cd mobile
flutter pub get
flutter run
```

> Make sure you have a valid `google-services.json` (Android) and `GoogleService-Info.plist` (iOS)
> in the appropriate directories — these are not committed to the repo.

---

## Key Conventions

### Flutter / Dart
- State management: Riverpod only — no raw setState for business logic
- Routing: go_router — all routes defined centrally in `lib/app/`
- Feature structure: `lib/features/{feature}/` — each feature owns its own screens, providers, and widgets
- HTTP: Dio client via shared service — never call `http` directly
- No hardcoded strings — use constants

### .NET API
- Follow existing Controller → Service → Repository pattern
- New endpoints go in `Controllers/`, business logic in `Services/`, data access in `Data/`
- Add EF migrations for any schema changes: `dotnet ef migrations add <Name>`
- Never commit secrets — use `appsettings.Development.json` (gitignored) for local config

### General
- No commented-out code committed to master
- PR description must explain the "why", not just the "what"
- Run tests before opening a PR

---

## CI

GitHub Actions runs on every PR:
- .NET 10 build + test
- Flutter widget analysis

PRs must pass CI before merging.

---

## Secrets & Config

| File | Purpose | Committed? |
|------|---------|-----------|
| `appsettings.Development.json` | Local API config | No |
| `google-services.json` | Firebase Android config | No |
| `GoogleService-Info.plist` | Firebase iOS config | No |
| `firebase_options.dart` | Firebase Flutter config (auto-generated) | Yes |

Never commit real secrets or API keys.
