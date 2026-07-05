# 🌍 MyLoop — Game Design Foundation

> **Walk the real world. Capture hexagon territory. Rise solo, and conquer with your clan.**
> This doc is the single source of truth — readable as a story for customers, precise enough to build from.
> _Mode: local only, not pushed. Status: ✅ locked · 🔵 open._

---

## 📖 Part 0 — The Decision Story (how we got here & why)

> Read top to bottom — each choice builds on the last. **✅ = locked.** This is the *why*; the *how* (mechanics) follows below.

**1 · The starting question.** A walking game where you capture real-world hexagon territory — but *who is it for, and why would anyone download it?* Everything below answers that.

**2 · Game or fitness? → GAME ✅.** You can't design for competitive gamers *and* wellness walkers — serving both softens the competition into mush no one can describe in a sentence. We chose **game**; *fitness is a free side-effect we advertise but never design around* (Pokémon GO's trick — fitness as trojan horse, not pitch). **Why game beat fitness** (re-checked, not assumed): fitness-walking is owned by Apple/Strava/Fitbit behind hardware+data moats a solo founder can't break; the competitive-territory lane is one they *won't* enter → defensible blue ocean, higher ceiling, and what the founder actually wants to build for years. **The catch we had to clear:** a competitive game dies with no one nearby — so the core *had* to be **solo-playable** (collect/loop/decay alone; stealing layers on with neighbours). It is. *If it weren't, we'd have chosen fitness.*

**3 · But nobody loves a hexagon.** Pokémon GO loaded 20 years of fandom into its install button; we have shapes. **The reframe:** territory games never ran on loving the *collectible* — Risk, Civ, Clash, Monopoly run on **owning, winning, "this is MINE."** So we don't sell the hex; we **manufacture** emotion from three feelings that need no IP — **"my streets"** (ownership) · **"someone near me wants them"** (rivalry) · **"look at my map"** (your colour spreading = the shareable flex). The hex is just the pixel the feeling is painted on.

**4 · Is the audience too small? → No, that's a myth ✅** (researched). Mobile gaming ≈ 3B people, ~52% women, avg age ~36, mostly casual — not lazy shut-ins. Pokémon GO ($6.3B lifetime, still ~$500M/yr) converted *tens of millions of normal people* who were neither gamers nor fitness buffs. **Size was never the risk — retention is.** Harry Potter: Wizards Unite had a top-3 IP and still died in 2 years, killed by *complexity + weak retention*, not audience. **We have no IP → even less margin → simple + sticky is survival, not preference.**

**5 · The flag → "Claim your city." ✅** Hyper-local, competitive, crew-based land-grab: your real neighbourhood is the board; your conquered map is your flag.

**6 · Money? → Prizes ignite, never sustain ✅.** No move-to-earn (StepN's per-step value bred bots → ponzi → collapse). A one-off **sponsored** prize ("King of the City") is allowed *only* as a launch spark to manufacture density — never ongoing (overjustification effect trains mercenaries and crowds out the real emotion), and only once anti-cheat can defend it.

**7 · How much to ship? → One simple spine, then layer by density ✅.** The proven killers are complexity and empty maps. Ship the smallest complete loop; add the rest **as the city fills**: **v1 spine → v2 duels + clans → v3 wars.** Never ship a layer the map is too empty to support.

**8 · The v1 core → 3 verbs ✅.** **Collect · Steal · Close-a-loop-to-capture-everything-inside.** Decay, shield, local leaderboard, missions, streak exist only to *support* these three.

**9 · The real bet → density, not features.** All of the above only ignites if we put enough players *near each other*. Mechanics are done; this is what's actually unsolved → **the open question we tackle next: which Stockholm pocket, and the first 50.**

### 📉 Evidence: the graveyard (why others failed)
| App | Got right | Why it failed / stayed small | Our move |
|---|---|---|---|
| Pokémon GO | IP emotion, social, simple verb | rural dead zones; needs IP + content | density-first; manufacture emotion |
| Ingress | deep core | complex, hardcore-only, no hook | dead-simple onboarding |
| **Turf** | our exact mechanic | no emotional wrapper → tiny for 10 yrs | identity + rivalry + word-of-mouth |
| **StepN** | explosive growth | per-step money → bots → ponzi collapse | never tie play to money |
| Strava | heatmap flex + social | not a game; premium fatigue | steal the flex, skip paywall core |
| Wizards Unite | top IP, big launch | too complex, weak retention → dead in 2 yrs | simple + sticky |

### 🔵 Still open
**Which dense Stockholm pocket + the first 50 players** · anti-cheat before any real-prize contest · final emotional-core wording.

---

## 🪜 Release roadmap — gated by density

> Ship ONE clear loop, then layer. **Release order = how many players a feature needs.** The app grows as the map fills. (The full design below is the *destination* — this is the order it ships in.)

| Phase | Ships | Needs | The pitch |
|---|---|---|---|
| **v1 — The Spine** | claim / hold / **steal** / defend / **decay** · local leaderboard · solo retention (missions, streak, achievements, XP→cosmetics) · **shield** · starter shield | works at **any** density (solo + ambient PvP with neighbours) | "Conquer and defend your city by walking" |
| **v2 — Structured competition** | **Duels** + Trophies + Tiers/Divisions (ghost-duel fallback) · **Clans** + chat + discovery | low density (duels via ghost); a few who group | "Prove you're the best — climb the ladder, form a crew" |
| **v3 — Social warfare** | **Clan Wars** · seasons · clan perks · competitive area-exploration | 5+ coordinated members × 2 clans | "Your crew conquers the city" |

**Rule:** never ship a layer the city is too empty to support. v1's only job is to prove the core bet — *people will walk to claim & defend turf* — as cheaply as possible (most of it already exists in code).

**🎯 v1 core — keep it exactly this simple (3 verbs):**
1. **Collect** — walk → the hexes you cross become yours.
2. **Steal** — walk through a neighbour's hex → it's yours.
3. **Close a loop → capture everything inside.**
Everything else (decay, shield, local leaderboard, missions, streak, XP→cosmetics) exists only to *support* these three. No duels/clans/wars in v1.

---

## 🗺️ The world in one picture

```mermaid
flowchart TD
    You((YOU)) -->|walk real streets| Solo[🟢 SOLO<br/>your territory · stealable · shield · decay]
    You -->|opt-in 6h, same tier| Duel[⚔️ DUEL 1v1<br/>resets each time · safe]
    You -->|clan war, 5–50| War[🏴 CLAN WAR<br/>clan vs clan · resets · safe]

    Solo --> Hex[💎 HEXES]
    Duel --> Tro[🏆 TROPHIES]
    War --> CT[🛡️ CLAN TROPHIES]
    You --> XP[✨ XP]

    Hex --> HU[map territory · leaderboard · clan strength]
    Tro --> TU[your Tier + Division]
    CT --> CU[clan division]
    XP --> XU[cosmetic unlocks]

    Duel -.net-new hexes.-> Solo
    War -.net-new hexes.-> Solo
```

---

## 📖 Maya's story (how every piece connects)

**Day 1 — First territory.** Maya installs in Stockholm, picks an avatar + colour, sets her home. A guided walk turns hexes green in real time; she loops back to her start and the whole block fills.
▸ _She owns **Hexes**, earned **XP**, sits at **Bronze I**. A **starter shield** protects her for her first days._

**Day 2 — Defend & maintain.** A neighbour walks her block and steals a few hexes — her **shield** caps the loss and gives recovery time. A push warns hexes will **decay** tonight; she re-walks to refresh.
▸ _Solo = **open world + shield + decay**. Territory is held, not just collected._

**Day 4 — First Duel.** She opts into a **Duel**: matched with a same-**Tier** player, 6 hours, a **fresh map starting at zero**. She plans an efficient **loop**, grabs a **5× bonus hex**, and watches her rival's **live bar** climb. Wins by 12.
▸ _**+30 Trophies** → climbing toward Silver. The brand-new land she grabbed flows into her **Solo** map. Her hex *total* only grew from the net-new — re-walking her own land just scored duel points._

**Week 2 — A clan.** She joins a clan (max **50**) as a **Scout**. Her hexes now add to **clan strength**.
▸ _Her territory does double duty: personal + clan power._

**Week 3 — Clan War.** With 5+ members, the **Captain** declares **War** (24h). Everyone walks and collects on the reset war map. The clan out-collects the rival.
▸ _**+Clan Trophies** → clan division rises. Maya personally banked **XP + net-new hexes** — but her **individual Trophies were untouched.**_

**Month 2 — Two ladders.** Promoted to **Ranger** (can invite). She climbs duels to **Gold**; the clan climbs its **own** division through wars. A weak dueller can still be a war hero.

---

## 💰 The three things you earn — and what each is FOR

| | 💎 **Hexes** | 🏆 **Trophies** | ✨ **XP** |
|---|---|---|---|
| **What it is** | Land you hold right now | Your skill rating | Lifetime progress |
| **Earn by** | Solo collecting; net-new in duels/wars | Duels: win **+30**, lose **−15** | Every action (capture, walk, steal, missions, streak) |
| **Can it drop?** | Yes — stolen (shield protects) + decay | Yes — lose a duel (tier-floor protected) | No — only rises |
| **What it drives** | Map territory · **Leaderboard** · **Clan strength** | Your **Tier + Division** (Bronze→Diamond, I–IV) · duel matchmaking | **Levels → cosmetic unlocks** (+ clan-create gate) |
| **What it helps you achieve** | Be #1 by territory; power your clan | Prove you're the best player; climb leagues | Personalize your look; flex status |

_(Clans have a parallel **Clan Trophies → Clan Division** ladder, fed by wars.)_

### 🎖️ What climbing Tiers & Divisions gives you
- **v1:** status everywhere (profile, leaderboard, clan roster) **+ a tier-exclusive cosmetic** each new tier (Gold skin, Diamond trail) — wearable status, no power.
- **v2:** **Seasons** — monthly soft-reset + exclusive seasonal cosmetics by peak tier (the CoC/Apex recurring chase).
- _Hexes rank you by **territory** (leaderboard); Trophies rank you by **duel skill** (Tier). Two identities, both "winning."_

---

## 🎮 Solo vs Duel vs Clan War — side by side

| | 🟢 **Solo (you)** | ⚔️ **Duel (1v1)** | 🏴 **Clan War (team)** |
|---|---|---|---|
| **What you do** | Walk, claim neutral/decayed land, defend yours | Opt-in 6h race vs a same-Tier player | Team (5–50) races a rival clan, 24h |
| **The map** | Persistent real world | Fresh 0-start overlay | Fresh 0-start overlay |
| **Stealable?** | Yes (shield protects) | No | No |
| **You earn** | Hexes, XP, missions, streak | ±Trophies, XP, net-new hexes | +XP, net-new hexes |
| **Affects YOU** | Hexes → leaderboard, clan strength | **Trophies → your Tier/Division** | XP + hexes only — **your Tier untouched** |
| **Affects CLAN** | Your hexes = clan strength | — | **Clan Trophies → clan division** |
| **Win condition** | (ongoing) | Higher score in 6h | Clan with higher total |

---

## 🔁 How wins & losses ripple

```mermaid
flowchart LR
    DW[Win duel] -->|+30| T[Your Trophies] --> Tier[Your Tier + Division ↑]
    DL[Lose duel] -->|−15| T
    WW[Clan wins war] -->|+| CTr[Clan Trophies] --> CD[Clan Division ↑]
    WL[Clan loses war] -->|−| CTr
    War[War, either result] -->|+XP, +net-new hexes| Me[You personally]
```

**Key rule:** duels are *your* ladder; wars are the *clan's* ladder. Helping your clan win a war never moves your personal Tier — but it grows your hexes, your XP, and your clan's standing.

---

## 🧠 How to win — strategy (duels **and** wars)

| Lever | The decision it creates | Built? |
|---|---|---|
| **Loops score big** | Close a loop → capture the whole interior. Smart routing beats raw steps. | ✅ exists |
| **Bonus hexes (5×)** | 3–5 high-value hexes appear; detour for them or sweep cheap land? | new |
| **Live opponent bar** | You see them gaining → push harder, time your final loop | new |
| **Best-of-3 objectives** | most hexes / biggest loop / most net-new → comeback paths | 🔵 v2 |
| **Clan coordination** | (wars) members link territory for a bonus | 🔵 v2 (needs density) |

---

## 👥 Clans

- **Max 50 members.** War needs **≥5**. Chat = **clan-only** (trash-talk to rivals → v2).
- **Clan strength = Σ members' current hex count** → clan leaderboard.
- **Clan discovery:** browse/search clans (sorted by division, activity, proximity) + request to join — so new players actually find a clan.
- High clan division → **cosmetic clan badge + bragging rights** (v1); perks (bigger cap, etc.) → v2.
- **Roles** (Scout → Ranger → Captain → Sovereign):

| Role | Can do |
|---|---|
| 👑 **Sovereign** (leader) | Everything; promote/demote anyone; transfer leadership; disband |
| ⭐ **Captain** (co-leader) | Declare & manage wars; kick and promote up to Ranger |
| 🎖️ **Ranger** (elder) | Invite players; accept join requests |
| 🚶 **Scout** (member) | Walk, contribute hexes, chat |

---

## 🔢 Numbers — v1 starting values (tune with live data)

**🛡️ Solo defense** — per-hex cooldown **6h** · steal cap per window **clamp(20% of holdings, 5–50)** · shield **(stolen÷X)×16h, min 4h** · shield burns **−20 min per hex you capture while shielded** · **starter shield 3 days / until 50 hexes** · decay 7d local→90d far.

**🏆 Trophy → Tier** — Bronze 0 · Silver 400 · Gold 1,000 · Platinum 1,800 · Crystal 2,800 · Diamond 4,000 (each = 4 divisions). Duel **win +30 / lose −15**, tier-floor protected. Matchmaking ±150 trophies. First 3 duels = placement.

**✨ XP & Levels** — `Level = 1 + √(XP/100)`. Capture +10 · steal +25 · walk +50/km · streak +20/day · all-missions +100 · achievements +25–1000. _(XP from actions only — no idle/territory income.)_

**🎨 Cosmetic unlocks** — L1 base skin+trail · L3 skin#2 · **L5 clan creation** + trail FX · L8 claim FX · L10 profile frame · L15 map theme · L20 premium skin · + seasonal drops from duel/war wins.

**⚔️ Duel / War** — Duel: **queue & search → push when matched → both get 6h**; **ghost-duel fallback** (race a same-tier player's recorded run) if no match in ~2 min. 3/day, same-division. War 24h, 5–50, same clan division. Bonus hexes 3–5 @ 5×.

**⚙️ Code constants (`GameConstants.cs`)** — `CellCooldownHours 0.0167→6.0` · rename/retire `HexTier` → trophy-driven `Tier` · add `ShieldMaxHours=16, ShieldFloorHours=4, StealCapPct=0.2(min5/max50), StarterShieldDays=3, ShieldBurnMinPerHex=20, TrophyWin=30, TrophyLoss=15` + division floors · fix seed users.

---

## 📌 Status & Launch
**Design locked** for all systems (01 Progression · 02 Clans · 03 Wars · 04 Cosmetics · 05 Numbers). **Shipped per the Release Roadmap, not all at once:** v1 = the Spine · v2 = Duels + Clans · v3 = Wars.
**Launch single-city: Stockholm** — multiplayer layers need local density; scattered = empty map. (Turf = proven appetite + competitor.)

### 🚦 Launch reality — shy, non-student solo founder
**GTM = online/content, not in-person hustle:** the conquered-map clip is the marketing (no face needed) on TikTok/IG/r/Stockholm; seed via ONE warm online community (local Discord/FB group/subreddit/run club); sponsored prize arranged by email; launch the **brand**, not yourself. (Campus-tabling = parked.)

**Design for city-level aliveness** (a sparse map must still feel live):
| Lever | Why sparse feels alive | v1? |
|---|---|---|
| Persistent enemy territory | others' turf stays on the map → raid it offline/across-town (**steal is async**) | ✅ core |
| Citywide leaderboard | chase a name, not a neighbour | ✅ |
| Neutral "wild"/landmark hexes | PvE conquest targets fill empty areas (honest, not fake players) | ➕ add v1 |
| Hotspots + activity pings | bonus hexes cluster at landmarks → sparse players converge; "3 hexes claimed near you today" | ➕ add v1 |
| Async/ghost duels | compete citywide, zero proximity | v2 |

**v1 competition framing = CITY scale** (leaderboard + raiding persisted turf + neutral hotspots); street-rivalry is the upgrade as density grows.
**⚠️ Caveat:** these make sparse feel *active* and buy a runway to density — they do NOT replace it; real-time rivalry/clans/wars still need it. Don't over-lean on PvE fill or we drift back to the cozy/solo game we rejected.

### 🤖 Bots / adaptive AI presence (decision)
Instinct (seed liveliness now, fade as real players arrive) = right shape. **What** the bots pretend to be is the whole risk:
- ✅ **Neutral "AI faction" / wild territory** that holds hexes and **adaptively recedes** as real players join — honest, fills the map, no trust risk.
- ✅ **Bot duel opponents** (v2) as accepted matchmaking fill.
- ❌ **Bots impersonating real humans** (fake names on leaderboard / in clans / "PlayerX stole your hexes") — banned. Three killers: (1) **GPS-plausibility** — fake walking is what our own anti-cheat is built to catch; (2) breaks our "never fake live players" rule; (3) breaks the core promise ("a *real* rival took my street") — and in a competitive game it always gets discovered → 1-star death.
- ✅ **Leaderboard stays 100% real**, even if short ("#3 of 11 in Stockholm"). A faked leaderboard is the most discoverable + most damaging move.

---

## ✅ Decisions locked this round
- Duel matching = **queue & search → push when matched → both 6h**, with **ghost-duel fallback** (recorded same-tier run) so duels always fire at launch.
- **Tier rewards** = status + tier-exclusive cosmetics (v1); **Seasons** (v2).
- **Clan division** = cosmetic clan badge + bragging (v1); perks (v2). **Clan discovery browser** added.
- `HexTier` → **Tier** (trophy-driven). **XP-income removed.**

## 🔵 Known issue to tune (not a blocker)
- **Duel fairness vs geography:** matched by skill, but a walking race also favours dense areas + free time. Loops + bonus hexes give an efficiency path. v1: accept; if telemetry shows geography dominating, switch duel scoring to **hexes-per-km**.

## ⏳ Later backlog (v2/v3)
Seasons · clan missions (keep clans alive between wars) · best-of-3 duel objectives · clan contiguity bonus · trash-talk chat · clan perks.

**Area exploration (H3 % of a district)** — verdict: useful for a *specific job* (low-density/solo bridge + onboarding ramp + spreads players out), **only in a COMPETITIVE framing** — rival %, explore-first → claim advantage, "first to 100% of a district" title. ❌ Never as cozy "complete your map" for its own sake = identity drift toward the wellness ocean we rejected. Ships v2/v3, never a pillar.
