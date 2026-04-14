# WA_SafeGuard

Automatic backup and recovery for WeakAuras on WoW 3.3.5a (WotLK).

Protects your WeakAuras configuration from being permanently wiped when a forced disconnect corrupts `WeakAuras.lua` in SavedVariables.

Built for Warmane and other 3.3.5a private servers.

---

## Table of Contents

- [The Problem](#the-problem)
- [Why .bak Does Not Help](#why-bak-does-not-help)
- [The Solution](#the-solution)
- [Installation](#installation)
- [Commands](#commands)
- [How It Works](#how-it-works-technical)
- [Example Output](#example-output)
- [FAQ](#faq)
- [File Structure](#file-structure)
- [Compatibility](#compatibility)
- [Contributing](#contributing)
- [Acknowledgments](#acknowledgments)

---

## The Problem

If you run two WoW clients and log into the same account from the second client, the first client is forcefully disconnected. During shutdown, WoW attempts to write all addon data (`SavedVariables`) to disk:

```
Normal logout:
  1. WoW serializes addon data
  2. Renames old WeakAuras.lua -> WeakAuras.lua.bak
  3. Creates new WeakAuras.lua
  4. Writes all data to file
  5. File closed, done

Forced disconnect:
  1. WoW serializes addon data
  2. Renames old WeakAuras.lua -> WeakAuras.lua.bak
  3. Creates new WeakAuras.lua
  4. Starts writing data... CLIENT KILLED
  5. WeakAuras.lua = 1 KB of garbage (truncated)
     WeakAuras.lua.bak = previous session's file
```

`WeakAuras.lua` often exceeds 5-30 MB, making it one of the largest SavedVariables files. The OS cannot flush that much data before the WoW process is terminated.

**Result:** All auras are permanently lost.

---

## Why `.bak` Does Not Help

The common workaround is to delete the broken file and rename the `.bak` file. This fails in practice:

1. WoW creates `.bak` by renaming the **current** `WeakAuras.lua` before writing the new one.
2. If the current file was already corrupted from a previous force DC, the `.bak` becomes a copy of corrupted data.
3. After two consecutive forced disconnects, both files are destroyed.

This is a cascading failure. Once the `.bak` mechanism is compromised, it cannot recover.

---

## The Solution

**WA_SafeGuard** is a lightweight companion addon that:

1. Stores a compressed backup of your WeakAuras data inside its own SavedVariables file.
2. Automatically detects corruption on login and restores your SavedVariables from backup.
3. Requires a single `/reload` after auto-restore to apply the data in-game.

### Why this works

WoW writes `SavedVariables` files in alphabetical order:

```
WA_SafeGuard.lua    ("WA_S...")  -> written FIRST
WeakAuras.lua       ("Weak...")  -> written SECOND
```

On a forced disconnect:
- `WA_SafeGuard.lua` (200-500 KB compressed) is fully written.
- `WeakAuras.lua` (5-30 MB) is interrupted.

The backup file is 3-5x smaller than the original due to:
- Cache stripping (removes auto-regenerated icon caches)
- Compact serialization (buffer-based writer, no whitespace)
- Huffman compression (via LibCompress, bundled with WeakAuras)

Small size + written first = survives the crash.

---

## Installation

### Manual Install

1. Download the latest release or clone the repository.
2. Extract or place the `WA_SafeGuard` folder into your WoW addons directory:
   ```
   WoW 3.3.5a/Interface/AddOns/WA_SafeGuard/
   ```
3. Verify the structure:
   ```
   Interface/AddOns/WA_SafeGuard/
   ├── WA_SafeGuard.toc
   ├── WA_SafeGuard.lua
   └── README.md
   ```
4. Restart WoW or type `/reload` in-game.
5. Ensure the addon is enabled on the character selection screen.

> **Important:** Install this addon while your WeakAuras are working correctly. The first backup is created on login. If your auras are already lost, reimport them first, then `/reload`.

---

## Commands

| Command | Description |
|---------|-------------|
| `/wastatus` | Show current status: WA health, backup size, backup age |
| `/wasave` | Force an immediate backup of current auras |
| `/warestore` | Manually restore auras from the last good backup |

### Automatic behavior

| Event | Action |
|-------|--------|
| **Login** (auras healthy) | Silently creates/updates backup |
| **Login** (auras corrupted) | Automatically overwrites SavedVariables with backup, prompts `/reload` |
| **Zone change / Logout** (clean) | Silently updates backup (via PLAYER_LEAVING_WORLD) |
| **Zone change / Logout** (auras corrupted) | Does nothing (preserves existing good backup) |

---

## How It Works (Technical)

### Flow diagram

```
┌─────────────────── LOGIN ─────────────────────────────────────────┐
│ Is WeakAurasSaved a valid table with a displays subtable?         │
│ ├─ YES (healthy)                                                  │
│ │   -> Strip caches from copy of WeakAurasSaved                   │
│ │   -> Serialize into compact Lua string                          │
│ │   -> Compress with LibCompress (if available)                   │
│ │   -> Store in WA_SafeGuardDB.data                               │
│ └─ NO (corrupted / missing)                                       │
│     -> Check if WA_SafeGuardDB.data exists                        │
│     ├─ YES -> Decode/Decompress/Deserialize -> Restore -> /reload │
│     └─ NO  -> Prompt manual reimport                              │
├─────────────────── LOGOUT ────────────────────────────────────────┤
│ Is WeakAurasSaved healthy?                                        │
│ ├─ YES -> Silently update WA_SafeGuardDB                          │
│ └─ NO  -> Do nothing                                              │
└───────────────────────────────────────────────────────────────────┘
```

### Serialization

The addon uses a custom buffer-based serializer. Unlike WoW's default `SavedVariables` writer, it produces compact, valid Lua strings without indentation or verbose key formatting.

### Compression

If **LibCompress** is available, the serialized string is Huffman-compressed and encoded. If unavailable, the raw string is stored.

### Corruption detection

Data is considered corrupted if:
- `WeakAurasSaved` is `nil` or not a table
- `WeakAurasSaved.displays` is not a table
- `WeakAurasSaved.displays` is empty while a valid backup exists

### Safety measures

- Sandboxed deserialization via `setfenv(fn, {})`
- Size validation (>50 bytes) prevents treating empty backups as valid
- Never overwrites a good backup with corrupted data
- `pcall` wraps all serialization/compression operations
- 3-second login delay ensures all addons finish loading before backup runs

---

## Example Output

### Healthy login (backup created)
```
[SafeGuard] Loaded. Commands: /wastatus /wasave /warestore
[SafeGuard] Backup OK  142 auras  ~1847KB
```

### Corrupted login (auto-restore)
```
[SafeGuard] Loaded. Commands: /wastatus /wasave /warestore
[SafeGuard] == WeakAuras data is CORRUPTED! ==
[SafeGuard] RESTORED 142 auras!
[SafeGuard] Auras restored to SavedVariables. Type /reload to apply.
```

### Status check
```
/wastatus

[SafeGuard] === Status ===
[SafeGuard] WeakAuras: OK (142 auras)
[SafeGuard] Backup: OK  142 auras  ~538KB  12 min ago
```

---

## FAQ

### Will this increase memory usage?
The compressed backup is typically 3-5x smaller than the original data. This is a negligible tradeoff for data integrity.

### What if both files get corrupted?
Extremely unlikely due to alphabetical write order and smaller size. If it occurs, check `WA_SafeGuard.lua.bak` in your SavedVariables folder.

### Does this work on other WoW versions?
Built and tested for 3.3.5a (WotLK). May work on 2.4.3 or 4.3.4 if `## Interface` is updated, but is untested.

### Can I use this without WeakAuras?
No. The addon only activates when WeakAuras data is present.

### How do I prevent the issue entirely?
Before logging into a second client, type `/reload` on the first. This forces a clean save of all SavedVariables.

### My auras are already gone. Can this recover them?
No. This addon prevents future loss. Reimport your auras, then `/reload`. The addon will protect them moving forward.

### How often is the backup updated?
On every login and logout, provided WeakAuras data is healthy. Use `/wasave` after adding new auras mid-session.

---

## File Structure

### Addon files
```
WA_SafeGuard/
├── WA_SafeGuard.toc
├── WA_SafeGuard.lua
└── README.md
```

### SavedVariables location
```
WTF/Account/<ACCOUNT_NAME>/SavedVariables/
├── WA_SafeGuard.lua
├── WA_SafeGuard.lua.bak
├── WeakAuras.lua
└── WeakAuras.lua.bak
```

---

## Compatibility

| Feature | Value |
|---------|-------|
| **WoW Version** | 3.3.5a (WotLK) |
| **Interface** | 30300 |
| **Tested On** | Warmane (Lordaeron, Icecrown, Frostmourne) |
| **WeakAuras** | Required |
| **LibCompress** | Optional (bundled with WeakAuras) |
| **Conflicts** | None known |

---

## Contributing

1. Open an issue describing the bug or feature.
2. Fork the repository and create a branch.
3. Commit changes following standard Lua/WoW conventions.
4. Submit a Pull Request with a clear description.

---

## Acknowledgments

- [WeakAuras for WotLK](https://github.com/NoM0Re/WeakAuras-WotLK)
- The Warmane community for stress-testing this edge case.

---

Developed to solve a persistent WeakAuras data loss issue on private servers. MIT License.