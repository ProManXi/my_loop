# MyLoop Frontend-Backend Architecture

Complete documentation of all API endpoints, SignalR hubs, WebSocket channels, and how Flutter services/Riverpod providers connect to .NET 10 controllers.

---

## 🏗️ System Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                      FLUTTER APP (Mobile)                        │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────┐        ┌──────────────────────────┐   │
│  │  Riverpod Providers │        │   Services & Listeners   │   │
│  │  (State Management) │        │                          │   │
│  │                     │        │  - ApiService (HTTP)     │   │
│  │ - authStateProvider │───────→│  - TerritoryRealtime     │   │
│  │ - userProfileProv.  │        │    (SignalR)             │   │
│  │ - xpSliceProvider   │        │  - LocationService       │   │
│  │ - journeyController │        │  - BatchDrainService     │   │
│  │ - explorationProv.  │        │  - StepClaimQueue        │   │
│  │ - achievementsProv. │        │                          │   │
│  └─────────────────────┘        └──────────────────────────┘   │
│           │                                │                    │
│           │ (watch/read)                   │ (HTTP + SignalR)   │
│           └───────────────┬────────────────┘                    │
│                           ▼                                     │
│                  ┌─────────────────┐                            │
│                  │   UI Widgets    │                            │
│                  │ (HomeTab, Map,  │                            │
│                  │  Journey, etc)  │                            │
│                  └─────────────────┘                            │
└──────────────────────────────────────────────────────────────────┘
                              ▲
                              │ HTTP (Bearer Token)
                              │ + SignalR (JWT via query string)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│                  .NET 10 API (Backend)                           │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Controllers (HTTP REST)                    │   │
│  │                                                         │   │
│  │  - UsersController       (auth, profile, game state)   │   │
│  │  - ClaimsController      (walk submission, step claim) │   │
│  │  - TerritoryController   (map queries, stats)          │   │
│  │  - MissionsController    (daily missions, XP)          │   │
│  │  - LeaderboardController (rankings)                    │   │
│  │  - AchievementsController (achievement tracking)       │   │
│  └─────────────────────────────────────────────────────────┘   │
│           │                         │                          │
│           ▼                         ▼                          │
│  ┌─────────────────┐      ┌──────────────────┐               │
│  │  TerritoryHub   │      │  Business Logic  │               │
│  │   (SignalR)     │      │   Services       │               │
│  │                 │      │                  │               │
│  │ - JoinRegion    │      │ - TerritoryService              │
│  │ - LeaveRegion   │      │ - MissionService                │
│  │ - JoinUserGroup │      │ - AchievementService            │
│  │ - LeaveUserGroup│      │ - UserService                   │
│  │                 │      │ - LeaderboardService            │
│  └─────────────────┘      └──────────────────┘               │
│           │                         │                          │
│           └─────────┬───────────────┘                          │
│                     ▼                                          │
│           ┌──────────────────────┐                            │
│           │   PostgreSQL 18      │                            │
│           │   (Database)         │                            │
│           └──────────────────────┘                            │
└──────────────────────────────────────────────────────────────────┘
```

---

## 📡 REST API Endpoints

### Authentication & User Management

| Endpoint | Method | Auth | Request Body | Response | Flutter Caller |
|----------|--------|------|--------------|----------|-----------------|
| `/api/users/register` | `POST` | ❌ No | `{firebaseUid, displayName, color, avatarId, authProvider}` | `{id, displayName, color, avatarId, ...}` | `auth_service.dart` → `apiService.register()` |
| `/api/users/by-uid/{firebaseUid}` | `GET` | ❌ No | — | `{id, displayName, ...}` or 404 | `auth_service.dart` → `apiService.getUserByUid()` |
| `/api/users/{id}` | `GET` | ✅ Yes | — | `{id, displayName, hexCount, level, ...}` | `apiService.getUser()` |
| `/api/users/{id}` | `PATCH` | ✅ Yes | `{displayName?, avatarId?, color?}` | `{id, displayName, color, ...}` | `apiService.updateUser()` |
| `/api/users/{id}/profile` | `GET` | ✅ Yes | — | `{id, displayName, rank, profile stats...}` | `apiService.getUserProfile()` |
| `/api/users/{id}/game-state` | `GET` | ✅ Yes | — | `{id, xp, missions[], achievements[], exploration[], rank}` | `apiService.getGameState()` |
| `/api/users/{id}/device-token` | `POST` | ✅ Yes | `{token, platform}` | 200 OK | `apiService.registerDeviceToken()` |
| `/api/users/{id}/home` | `POST` | ✅ Yes | `{lat, lng}` | `{homeLat, homeLng, homeCity, homeState, homeCountry, homeContinent}` | `apiService.setHome()` |
| `/api/users/{id}/claims` | `GET` | ✅ Yes | Query: `page`, `pageSize` | `[{date, totalCells, totalAreaM2, claimsCount, firstClaimed}]` | `apiService.getWalkHistory()` |
| `/api/users/{id}` | `DELETE` | ✅ Yes | — | 204 No Content | `apiService.deleteAccount()` |

### Territory Claims & Walking

| Endpoint | Method | Auth | Request Body | Response | Flutter Caller |
|----------|--------|------|--------------|----------|-----------------|
| `/api/claims` | `POST` | ✅ Yes | `{userId, path: [[lat,lng]...]}` | `{id, cellCount, areaM2, createdAt}` | `apiService.submitClaim()` |
| `/api/claims/batch-step` | `POST` | ✅ Yes | `{userId, localDate, points: [{lat,lng}...]}` | `{results: [], stats: {hexCount, totalCaptured, totalStolen, ...}, xp: {...}, missions: [], achievements: []}` | `apiService.claimBatchStep()` |
| `/api/claims/preview` | `POST` | ✅ Yes | `{path: [[lat,lng]...]}` | `{boundaries: [[[lat,lng]...]...]}` | `apiService.previewClaim()` |

### Territory Queries

| Endpoint | Method | Auth | Query Parameters | Response | Flutter Caller |
|----------|--------|------|------------------|----------|-----------------|
| `/api/territories` | `GET` | ✅ Yes | `minLat, minLng, maxLat, maxLng` | `[{cellId, h3Index, ownerId, ownerDisplayName, ownerColor, centerLat, centerLng, ...}]` | `journey_controller.dart` → `apiService.getTerritories()` |
| `/api/territories/user/{userId}` | `GET` | ✅ Yes | — | `[{cellId, h3Index, ownerId, ...}]` | `apiService.getUserTerritories()` |
| `/api/territories/stats/{userId}` | `GET` | ✅ Yes | — | `{totalCells, totalAreaM2}` | `territoryService.GetStats()` |
| `/api/territories/stolen/{userId}` | `GET` | ✅ Yes | `days?` (default 7) | `[{cellId, h3Index, previousOwnerId, stolenAt, ...}]` | Territory UI component |
| `/api/territories/history/{cellId}` | `GET` | ✅ Yes | — | `[{cellId, ownerId, ownerName, claimedAt, ...}]` | Cell detail view |
| `/api/territories/claims/{userId}` | `GET` | ✅ Yes | — | `[{date, totalCells, totalAreaM2, claimsCount, firstClaimed}]` | Hex history UI |
| `/api/territories/exploration/{userId}` | `GET` | ✅ Yes | `lat, lng` | `[{neighborhoodId, centerLat, centerLng, exploredCount, ownedCount, totalCount, percent, areaName}]` | `explorationProvider` → `apiService.getExplorationStats()` |

### Missions & XP

| Endpoint | Method | Auth | Query Parameters | Response | Flutter Caller |
|----------|--------|------|------------------|----------|-----------------|
| `/api/missions/{userId}` | `GET` | ✅ Yes | — | `[{id, type, description, targetValue, currentProgress, xpReward, isCompleted, completedAt}]` | `dailyMissionsProvider` → `apiService.getDailyMissions()` |
| `/api/missions/xp/{userId}` | `GET` | ✅ Yes | — | `{totalXp, level, progressXp, neededXp, progressPercent}` | `xpInfoProvider` → `apiService` |

### Leaderboard

| Endpoint | Method | Auth | Query Parameters | Response | Flutter Caller |
|----------|--------|------|------------------|----------|-----------------|
| `/api/leaderboard` | `GET` | ✅ Yes | `lat, lng, userId?, scope` | `{entries: [{rank, userId, displayName, hexCount, ...}], userRank, scope}` | `cityLeaderboardProvider` → `apiService.getLeaderboard()` |
| `/api/leaderboard/refresh` | `POST` | ✅ Yes | — | `{message, playerCount}` | `apiService.refreshLeaderboard()` |

### Achievements

| Endpoint | Method | Auth | Query Parameters | Response | Flutter Caller |
|----------|--------|------|------------------|----------|-----------------|
| `/api/achievements/{userId}` | `GET` | ✅ Yes | — | `[{id, name, description, icon, xpReward, progress, isUnlocked, unlockedAt}]` | `achievementsProvider` → `apiService` |

---

## 🔌 SignalR Hub: `TerritoryHub`

**Connection URL**: `/hubs/territory`

**Authentication**: Firebase JWT passed via query string: `/hubs/territory?access_token={token}`

### Client → Server Methods (Invocations)

| Method | Parameters | Purpose | Auth | Called From |
|--------|-----------|---------|------|-------------|
| `JoinRegion(regionId)` | `regionId: string` (H3 res-3 parent) | Subscribe to public hex updates for a geographic area (~12,000 km²) | ❌ No | `territoryRealtimeService.joinRegion()` |
| `LeaveRegion(regionId)` | `regionId: string` | Unsubscribe from region updates (e.g., when panning map away) | ❌ No | `territoryRealtimeService.leaveRegion()` |
| `JoinUserGroup()` | (no parameters) | Subscribe to personal state deltas (stats, XP, missions, achievements). UserId extracted from JWT claims server-side. | ✅ Yes | `territoryRealtimeService.connect()` + `_resubscribeAll()` |
| `LeaveUserGroup()` | (no parameters) | Unsubscribe from personal group (e.g., on logout) | ✅ Yes | `territoryRealtimeService.disconnect()` |

### Server → Client Events (Push Notifications)

| Event Name | Payload | Scope | Description | Riverpod Listener |
|-----------|---------|-------|-------------|-------------------|
| `HexOwnershipChanged` | `[{h3Index, centerLat, centerLng, newOwnerId, newOwnerColor, newOwnerDisplayName, previousOwnerId}]` | Region Group | Broadcast when a hex is claimed or stolen. All clients subscribed to that region receive it. | `territoryRealtimeService.onHexChanges` → Map renders hex color changes |
| `UserStatsDelta` | `{hexCount, totalHexesCaptured, totalHexesStolen, streak, isStreakActive, distanceKm}` | User Group (`user_{userId}`) | Personal stats update after a claim (hex count, stolen count, streak). **Real-time hex counter on home tab**. | `userRealtimeListenerProvider` → `userProfileProvider.updateStats()` |
| `XpDelta` | `{xpGained, totalXp, level, leveledUp, progressXp, neededXp, progressPercent}` | User Group | XP and level update. Fires when user claims hexes or completes missions. | `territoryRealtimeService.onXp` → XP bar updates |
| `MissionDelta` | `{updates: [{missionId, type, currentProgress, targetValue, completed, xpAwarded}], allMissionsComplete, bonusXp}` | User Group | Daily mission progress update. Deduplicated to final state per mission. | `territoryRealtimeService.onMissions` → Mission list updates |
| `AchievementUnlocked` | `{unlocks: [{id, name, icon, xpAwarded}]}` | User Group | Achievement unlock notification. | `territoryRealtimeService.onAchievements` → Achievement toast/popup |

---

## 📱 Flutter Services & Riverpod Providers

### Service Layer (Stateless, Injectable)

| Service | File | Purpose | Key Methods | Backend Connection |
|---------|------|---------|-------------|-------------------|
| **ApiService** | `api_service.dart` | HTTP REST client using Dio | `register()`, `getTerritories()`, `claimStep()`, `claimBatchStep()`, `getGameState()`, `getLeaderboard()`, `getDailyMissions()` | REST API endpoints (all HTTP endpoints above) |
| **AuthService** | `auth_service.dart` | Firebase Auth wrapper | `signInWithGoogle()`, `signInWithApple()`, `signOut()`, `getCurrentUser()` | Firebase auth (not MyLoop backend) |
| **TerritoryRealtimeService** | `territory_realtime_service.dart` | SignalR hub connection | `connect()`, `disconnect()`, `joinRegion()`, `leaveRegion()` | TerritoryHub (SignalR) |
| **LocationService** | `location_service.dart` | GPS tracking (Geolocator) | `getLocationUpdates()`, `getCurrentLocation()`, `requestPermission()` | Device GPS (no backend) |
| **BatchDrainService** | `batch_drain_service.dart` | Batches GPS points, drains to API on timer or threshold | `startDrain()`, `stopDrain()` | `/api/claims/batch-step` |
| **StepClaimQueue** | `step_claim_queue.dart` | Persistent write-ahead log (JSONL file) | `enqueue()`, `peek()`, `dequeue()`, `drainAll()` | Device storage (no backend) |
| **PushNotificationService** | `push_notification_service.dart` | FCM device token registration | `initialize()`, `registerToken()` | `/api/users/{id}/device-token` |

### Riverpod Providers (State Management)

#### Service Providers

| Provider | File | Type | Purpose |
|----------|------|------|---------|
| `apiServiceProvider` | `api_service.dart` | `Provider` | Singleton ApiService instance |
| `authServiceProvider` | `auth_service.dart` | `Provider` | Singleton AuthService instance |
| `authStateProvider` | `auth_service.dart` | `StreamProvider<User?>` | Reactive Firebase auth state (login/logout) |
| `locationServiceProvider` | `location_service.dart` | `Provider` | Singleton LocationService instance |
| `territoryRealtimeProvider` | `territory_realtime_service.dart` | `Provider` | Singleton TerritoryRealtimeService (SignalR connection) |
| `pushNotificationProvider` | `push_notification_service.dart` | `Provider` | Singleton PushNotificationService instance |
| `userRealtimeListenerProvider` | `user_realtime_listener.dart` | `AsyncNotifierProvider` | Watches auth user, subscribes to SignalR UserStatsDelta |

#### State Slices (Business Logic)

| Provider | File | Type | State | Updates From | Used By |
|----------|------|------|-------|--------------|---------|
| `userProfileProvider` | `user_state.dart` | `NotifierProvider` | `UserProfile {userId, displayName, hexCount, streak, level, ...}` | API on login + SignalR UserStatsDelta | Home tab hex counter, profile UI |
| `profileSliceProvider` | `profile_slice.dart` | `NotifierProvider` | `ProfileState {user, loadingUser, errorUser, ...}` | API `/api/users/{id}/game-state` | Home tab, profile drawer |
| `xpSliceProvider` | `xp_slice.dart` | `NotifierProvider` | `XpState {totalXp, level, progressXp, progressPercent, ...}` | API + SignalR XpDelta | XP bar, level-up celebration |
| `missionsSliceProvider` | `missions_slice.dart` | `NotifierProvider` | `MissionsState {missions: [], completed: int, ...}` | API `/api/missions/{userId}` + SignalR MissionDelta | Daily missions list |
| `achievementsSliceProvider` | `achievements_slice.dart` | `NotifierProvider` | `AchievementsState {achievements: [], isLoaded, ...}` | API `/api/achievements/{userId}` + SignalR AchievementDelta | Achievements screen |
| `journeyControllerProvider` | `journey_controller.dart` | `NotifierProvider` | `JourneyState {status, path, distanceMeters, claimedCount, xpGainedThisWalk, ...}` | `LocationService` + API `/api/claims/batch-step` | Journey (walk) screen |
| `homeTabLoadedProvider` | `home_tab.dart` | `NotifierProvider` | `bool` | Set on home tab init | Controls data loading trigger |

#### Feature-Specific Providers

| Provider | File | Type | Purpose | Calls |
|----------|------|------|---------|-------|
| `dailyMissionsProvider` | `home_tab.dart` | `Provider` | Returns today's missions from `missionsSliceProvider` | Read-only view of missions |
| `xpInfoProvider` | `home_tab.dart` | `Provider` | Returns XP info from `xpSliceProvider` | Read-only view of XP progress |
| `achievementsProvider` | `home_tab.dart` | `Provider` | Returns achievements from `achievementsSliceProvider` | Read-only view of achievements |
| `explorationProvider` | `home_tab.dart` | `Provider` | Fetches exploration neighborhoods | `apiService.getExplorationStats()` |
| `cityLeaderboardProvider` | `leaderboard_screen.dart` | `FutureProvider.autoDispose` | Fetches leaderboard for current location | `apiService.getLeaderboard()` |

---

## 🔄 End-to-End Data Flows

### Flow 1: User Registration & Login

```
Flutter App (AuthService)
    ↓
1. User taps "Google Sign-In"
    ↓
FirebaseAuth.signInWithGoogle()
    ↓
Firebase Cloud (OAuth)
    ↓
2. App receives Firebase JWT + UID
    ↓
apiService.getUserByUid(firebaseUid)
    ↓
GET /api/users/by-uid/{firebaseUid}
    ↓ (404 → Not registered)
apiService.register(firebaseUid, displayName, color, avatarId)
    ↓
POST /api/users/register
    ↓
(Backend: Create User in DB)
    ↓
Response: {id, displayName, hexCount: 0, ...}
    ↓
userProfileProvider.setFromApi(...)
    ↓
3. UI shows home screen
```

### Flow 2: Real-Time Hex Count Update During Walk

```
Journey Running (LocationService GPS tick)
    ↓
GPS point → batch queue (StepClaimQueue)
    ↓
(After 10s timer OR 5 points threshold)
    ↓
BatchDrainService triggers POST /api/claims/batch-step
    ↓
└─ {userId, localDate, points: [{lat,lng}...]}
    ↓
(Backend: ProcessBatchStepClaim → claim cells → save)
    ↓
Response: BatchStepClaimResponse {
  results: [...],
  stats: {hexCount: 42, ...},
  xp: {xpGained: 50, level: 5, ...},
  missions: [...],
  achievements: [...]
}
    ↓
journeyControllerProvider.updateWithResult(result)
    ↓ (Fire-and-forget)
TerritoryNotifier.PushPersonalDeltas(userId, ...)
    ↓
SignalR broadcast to user_{userId} group
    ↓
┌─ Event: UserStatsDelta {hexCount: 42, ...}
│
└─ territoryRealtimeService.onUserStats stream
    ↓
userRealtimeListenerProvider receives delta
    ↓
userProfileProvider.updateStats(hexCount: 42)
    ↓
Home tab hex counter updates LIVE
└─ UI rebuilds with new count
```

### Flow 3: Friend Captures Hex on Map (Public Broadcast)

```
Friend's Journey (User B)
    ↓
Calls POST /api/claims/step {userId: B, lat, lng}
    ↓
(Backend: Captures cell from User A)
    ↓
TerritoryService.BroadcastOwnershipChanges()
    ↓
SignalR broadcast to region group: `{regionId}` (H3 res-3 parent)
    ↓
Event: HexOwnershipChanged {
  h3Index: "...",
  newOwnerId: B,
  newOwnerColor: "#FF0000",
  previousOwnerId: A
}
    ↓
Your App (if subscribed to region)
    ↓
journeyControllerProvider.joinRegion(regionId)
    ↓
territoryRealtimeService.onHexChanges stream
    ↓
Journey Map receives HexChangeEvent
    ↓
Updates map canvas:
  - Remove old hex with A's color
  - Draw new hex with B's color
    ↓
UI instantly shows friend's steal on YOUR map
```

### Flow 4: Daily Mission Progress Update

```
User claims hexes
    ↓
POST /api/claims/batch-step
    ↓
(Backend: ProcessBatchStepClaim evaluates all missions)
    ↓
Mission: "Claim 10 hexes today" → progress updates 7 → 10 (COMPLETE!)
    ↓
TerritoryNotifier.NotifyMissionAsync(userId, MissionDelta)
    ↓
SignalR broadcast to user_{userId} group
    ↓
Event: MissionDelta {
  updates: [{missionId, currentProgress: 10, completed: true, xpAwarded: 50}],
  allMissionsComplete: false,
  bonusXp: 0
}
    ↓
App receives MissionDelta
    ↓
missionsSliceProvider.updateFromDelta(delta)
    ↓
Mission UI updates:
  - Progress bar fills to 100%
  - ✅ Completed badge appears
  - XP gained notification
```

### Flow 5: Achievement Unlock

```
User achieves milestone (e.g., "Capture 1000 hexes total")
    ↓
POST /api/claims/batch-step → claims 50 hexes
    ↓
(Backend: Total hex count reaches 1000)
    ↓
AchievementService detects milestone
    ↓
TerritoryNotifier.NotifyAchievementAsync(userId, AchievementUnlocked[])
    ↓
SignalR broadcast to user_{userId} group
    ↓
Event: AchievementUnlocked {
  unlocks: [{id: "hexmaster1k", name: "Hex Master", icon: "🏆", xpAwarded: 200}]
}
    ↓
App receives AchievementDelta
    ↓
achievementsSliceProvider marks achievement unlocked
    ↓
Journey screen shows toast: "🏆 Achievement: Hex Master +200 XP"
    ↓
Celebration dialog pops up
```

### Flow 6: Exploration Stats Query

```
User scrolls to new area on journey map
    ↓
Current GPS: {lat: 59.3293, lng: 18.0686}
    ↓
explorationProvider triggers fetch
    ↓
apiService.getExplorationStats(userId, lat, lng)
    ↓
GET /api/territories/exploration/{userId}?lat=59.3293&lng=18.0686
    ↓
(Backend: Find H3 res-8 neighborhoods near point)
    ↓
For each neighborhood:
  - Count explored cells (ExploredCells table)
  - Count owned cells (TerritoryCells where ownerId=userId)
  - Total possible cells (H3 children count)
  - Reverse geocode center to area name (Nominatim)
    ↓
Response: [
  {
    neighborhoodId: 612...,
    centerLat: 59.33,
    centerLng: 18.07,
    exploredCount: 120,
    ownedCount: 32,
    totalCount: 343,
    percent: 35.0,
    areaName: "Sampangirama Nagar"
  },
  ...
]
    ↓
explorationProvider caches result
    ↓
Home tab "Exploration" section renders:
  ┌─ Sampangirama Nagar
  │  Explored: 120 / 343 (35%)
  │  Owned: 32 / 343
  └─ [Map of nearby areas]
```

### Flow 7: Walk History (Daily Grouping)

```
User views "Walk History" tab
    ↓
apiService.getWalkHistory(userId, page=1)
    ↓
GET /api/users/{userId}/claims?page=1&pageSize=20
    ↓
(Backend: Query Claims table, GROUP BY DATE)
    ↓
Response: [
  {
    date: "2026-06-01",
    totalCells: 127,
    totalAreaM2: 950000,
    claimsCount: 3,          ← 3 walk submissions that day
    firstClaimed: "2026-06-01T18:45:00Z"
  },
  {
    date: "2026-05-31",
    totalCells: 89,
    totalAreaM2: 670000,
    claimsCount: 2,
    firstClaimed: "2026-05-31T16:30:00Z"
  },
  ...
]
    ↓
UI renders daily rows:
  ┌─ June 1: 127 cells, 950k m²
  │  (3 walks today)
  └─ May 31: 89 cells, 670k m²
     (2 walks today)
```

---

## 🔐 Authentication & Authorization

### Request Headers (All Protected Endpoints)

```http
GET /api/territories?minLat=59.3&minLng=18.0&maxLat=59.4&maxLng=18.1
Authorization: Bearer {Firebase JWT}
```

**Firebase JWT contains:**
- `sub` (subject) = Firebase UID
- `email` = User email
- `iat` = Issued at
- `exp` = Expiration (1 hour)

**Backend validates:**
1. JWT signature (Firebase public key)
2. Expiration time
3. Claims presence

### SignalR Authentication

**Query String:**
```
/hubs/territory?access_token={Firebase%20JWT}
```

**Process:**
1. Client connects with token in query string
2. Backend extracts token via `OnMessageReceived` event
3. Validates JWT
4. Sets `Context.User` claims
5. JoinUserGroup() extracts `userId` from `ClaimTypes.NameIdentifier` (read-only from JWT)

---

## 🔄 State Management Flow (Riverpod)

```
┌─────────────────────────────────────────────────────────────┐
│           Riverpod Provider Hierarchy                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Service Providers (Singletons, Never Rebuild)       │   │
│  │                                                      │   │
│  │ - apiServiceProvider (HTTP)                         │   │
│  │ - authServiceProvider (Firebase)                    │   │
│  │ - territoryRealtimeProvider (SignalR)               │   │
│  │ - locationServiceProvider (GPS)                     │   │
│  └──────────────────────────────────────────────────────┘   │
│                     ▲                                       │
│                     │ (read)                                │
│  ┌──────────────────┴───────────────────────────────────┐   │
│  │ State Slice Providers (Auto-update from Services)   │   │
│  │                                                      │   │
│  │ - userProfileProvider                               │   │
│  │   (watches userRealtimeListenerProvider)             │   │
│  │                                                      │   │
│  │ - missionsSliceProvider                             │   │
│  │   (listens to territoryRealtimeProvider.onMissions) │   │
│  │                                                      │   │
│  │ - xpSliceProvider                                   │   │
│  │   (listens to territoryRealtimeProvider.onXp)       │   │
│  │                                                      │   │
│  │ - journeyControllerProvider                         │   │
│  │   (listens to LocationService GPS + API responses) │   │
│  └──────────────────────────────────────────────────────┘   │
│                     ▲                                       │
│                     │ (watch)                               │
│  ┌──────────────────┴───────────────────────────────────┐   │
│  │ UI Widgets (Rebuilds on State Change)               │   │
│  │                                                      │   │
│  │ - HomeTab (hexCount, streak, XP, missions)          │   │
│  │ - JourneyScreen (live walk stats)                   │   │
│  │ - LeaderboardScreen (ranked players)                │   │
│  │ - AchievementsScreen (unlocked badges)              │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 📊 Data Model Relationships

### Database Tables

```
┌─────────────────────────────────────────────────────────────┐
│                    Users                                    │
├─────────────────────────────────────────────────────────────┤
│ Id (PK) │ FirebaseUid │ DisplayName │ HexCount │ Level │ ...│
│         │             │             │          │       │    │
│         ├─────────────┴─────────────┴──────────┴───────┤    │
│         │ (1) User claims hexes → HexCount++         │    │
│         └────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                     │
                     │ owns (1:M)
                     ▼
┌─────────────────────────────────────────────────────────────┐
│              TerritoryCells                                 │
├─────────────────────────────────────────────────────────────┤
│ CellId (PK) │ OwnerId (FK) │ NeighborhoodId │ ClaimedAt │ ..│
│ H3 index    │ to Users     │ H3 res-8       │ Timestamp │   │
│ (long)      │              │ parent         │           │   │
└─────────────────────────────────────────────────────────────┘
                                │
                                │ (M:M via neighborhood)
                                ▼
┌─────────────────────────────────────────────────────────────┐
│           ExploredCells                                     │
├─────────────────────────────────────────────────────────────┤
│ UserId (PK FK) │ CellId (PK FK) │ NeighborhoodId │ FirstVisit│
│ to Users       │ to TerritoryCells │ H3 res-8   │ Timestamp │
└─────────────────────────────────────────────────────────────┘
                     │
                     │ (1:M per user per day)
                     ▼
┌─────────────────────────────────────────────────────────────┐
│              Claims                                         │
├─────────────────────────────────────────────────────────────┤
│ Id (PK) │ UserId (FK) │ CellCount │ AreaM2 │ CreatedAt │ ..│
│ UUID    │ to Users    │ int       │ float  │ Timestamp │   │
│         │             │ (27 hex=100m²)                │   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│           CellTransfers (Steals)                            │
├─────────────────────────────────────────────────────────────┤
│ Id │ CellId (FK) │ FromUserId (FK) │ ToUserId (FK) │ At │ ..│
│    │ to TerritoryCell │ to Users       │ to Users       │   │
│    │ (thief steals from victim)                         │   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│          Achievements                                       │
├─────────────────────────────────────────────────────────────┤
│ Id │ Name │ Description │ Icon │ XpReward │ UnlockCondition│
└─────────────────────────────────────────────────────────────┘
                     │
                     │ (1:M)
                     ▼
┌─────────────────────────────────────────────────────────────┐
│       UserAchievements                                      │
├─────────────────────────────────────────────────────────────┤
│ UserId (PK FK) │ AchievementId (PK FK) │ UnlockedAt (nullable)
│ to Users       │ to Achievements       │ Null = locked     │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│         DailyMissions                                       │
├─────────────────────────────────────────────────────────────┤
│ Id │ UserId (FK) │ Type │ TargetValue │ CurrentProgress │ ..│
│    │ to Users    │ e.g. │ 10 hexes    │ 7 so far        │   │
│    │             │ "ClaimHexes"      │                 │   │
└─────────────────────────────────────────────────────────────┘
```

---

## 🎯 Real-Time vs Request-Response

### Real-Time Events (SignalR Push)

- **HexOwnershipChanged**: Instant regional broadcast when hex claimed/stolen
- **UserStatsDelta**: Instant personal update of hex count after claim
- **XpDelta**: Instant level-up notification
- **MissionDelta**: Instant mission progress (deduplicated to final state)
- **AchievementUnlocked**: Instant achievement notification

### Request-Response (HTTP REST)

- **Game State Hydration**: `/api/users/{id}/game-state` (called once on app load)
- **Exploration Stats**: `/api/territories/exploration/{id}` (polling as user moves)
- **Leaderboard**: `/api/leaderboard` (user-initiated refresh)
- **Walk History**: `/api/users/{id}/claims` (paginated on demand)
- **Territory Viewport**: `/api/territories?minLat=...` (pan/zoom triggers query)

### Why the Mix?

- **Push (SignalR)**: Latency-critical user feedback (hex counter, achievements)
- **Pull (REST)**: Large data sets, user-initiated queries, non-time-critical

---

## 📐 Performance Optimizations

### Batch Claim Pipeline (Write-Ahead Log)

```
GPS Points → Queue (StepClaimQueue)
            ↓
         [Buffer for 10s OR 5 points]
            ↓
         BatchDrainService
            ↓
    POST /api/claims/batch-step
            ↓
[Single DB transaction, single SaveChanges, one SignalR push]
            ↓
     Exponential backoff on failure (1s → 2s → 4s → 8s → 16s → 30s)
```

**Result**: 
- ✅ Reduces network round-trips (many points in 1 request)
- ✅ Single DB transaction (ACID guarantees)
- ✅ Resilient to network hiccups (queue persists to disk)

### Real-Time Subscriptions (SignalR Groups)

```
┌─ Region Groups (Public)
│  Group name: "{h3_res3_parent_id}"
│  Broadcast: HexOwnershipChanged
│  Members: All app instances near that region
│  Scalability: Only broadcast to interested clients
│
└─ User Groups (Private)
   Group name: "user_{userId}"
   Broadcast: UserStatsDelta, XpDelta, MissionDelta, AchievementUnlocked
   Members: Only that user's app instances
   Security: JWT-validated extraction of userId
```

### Exploration Stats Caching

- Frontend: Provider caches result during session
- Backend: No DB-level caching (computed on-demand via H3 polyfill)
- Re-fetches: On significant GPS movement (lat/lng change > threshold)

### Leaderboard Refresh

- Cached in memory (refreshed hourly via background job)
- POST endpoint for on-demand refresh after user's claim

---

## 🚀 Deployment Architecture

```
┌────────────────────────────────────────────────────────────┐
│          Mobile (iOS + Android)                            │
│  - Firebase Auth (Google, Apple)                           │
│  - Flutter SDK                                             │
└────────────────────────────────────────────────────────────┘
                         │
                  ngrok tunnel (dev)
                  or custom domain (prod)
                         │
                         ▼
┌────────────────────────────────────────────────────────────┐
│      .NET 10 API (AWS/Azure/GCP)                           │
│  - appsettings.json (secrets manager)                      │
│  - Entity Framework Core + PostgreSQL 18                   │
│  - SignalR hub registration                                │
└────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────┐
│      PostgreSQL 18 (Cloud SQL / RDS / Managed Postgres)    │
│  - Users, TerritoryCells, Achievements, etc.               │
│  - Backups enabled                                         │
│  - SSL/TLS connection required                             │
└────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────┐
│      Firebase Project (myloop-6aefc)                       │
│  - Authentication (Google, Apple providers)                │
│  - JWT signing key (public key for API validation)         │
│  - FCM for push notifications                              │
│  - Cloud Messaging (optional)                              │
└────────────────────────────────────────────────────────────┘
```

---

## 🔍 Debugging Checklist

### "API calls not working"

1. ✅ Check Bearer token in Authorization header
2. ✅ Verify Firebase JWT not expired (`exp` claim)
3. ✅ Check ngrok tunnel is active: `curl https://your-tunnel.ngrok-free.app/`
4. ✅ Verify API_URL environment variable points to correct base URL
5. ✅ Check API controller route attributes match request path

### "SignalR not receiving events"

1. ✅ Verify WebSocket connection established: check browser DevTools Network tab
2. ✅ Confirm `JoinRegion(regionId)` or `JoinUserGroup()` invoked after connect
3. ✅ Check Firebase JWT passed via query string, not None/empty
4. ✅ Verify backend broadcasts to correct group name (e.g., `user_{userId}` not `user_wrong_id`)
5. ✅ Check TerritoryHub methods actually call `_hubContext.Clients.Group(...).SendAsync(...)`

### "Hex count not updating real-time"

1. ✅ Verify `/api/claims/batch-step` returns successfully (check response)
2. ✅ Confirm `PushPersonalDeltas()` called after claim transaction commits
3. ✅ Check `UserStatsDelta` event received in `territoryRealtimeService.onUserStats`
4. ✅ Verify `userRealtimeListenerProvider` is being watched in HomeScreen
5. ✅ Confirm `userProfileProvider.updateStats()` called with new hexCount

### "404 on POST /api/claims/batch-step"

1. ✅ Verify endpoint exists in ClaimsController
2. ✅ Check request body format: `{userId, localDate, points: [{lat,lng}...]}`
3. ✅ Validate coordinates in range: lat ∈ [-90, 90], lng ∈ [-180, 180]
4. ✅ Confirm no NaN/Infinity values

