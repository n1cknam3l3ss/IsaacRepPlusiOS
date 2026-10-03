# IsaacRepPlusiOS

Standalone iOS tweak bringing key **Repentance+ (v1.9.x)** quality-of-life and balance features to *The Binding of Isaac: Repentance* on iOS (Build UUID: `F4357753-A25F-30EE-BACF-63709F902895`).

## Features

### 1. Guaranteed Void Portals (100% Chance)
In vanilla Repentance iOS (v1.7.9b), reaching Delirium from alternative paths was locked behind harsh RNG (50% on Mega Satan, 20% on Lamb/Blue Baby, 0% on Mother).
`IsaacRepPlusiOS` guarantees a **100% chance** Delirium Void portal spawn immediately after defeating:
- **Mega Satan** (Chest / Dark Room)
- **Mother** (Corpse II)
- **The Lamb** (Dark Room)
- **??? / Blue Baby** (Chest)

The Void Portal is spawned natively via the game's internal `Room::SpawnGridEntity` API as `GridEntity_TrapDoor` with `VarData = 1`, ensuring seamless transition directly to Stage 12 (The Void) with full game engine and savegame stability.

### 2. Repentance+ Balance Changes
- **Revelation (ID 643)**: Removed +2 soul hearts upon pickup (`soulhearts = 0`). Flight and holy beam preserved.
- **Mega Bean (ID 351)**: Reworked max charges to 6 (`maxcharges = 6`).
- **2Spooky (ID 554)**: Quality upgraded to 2 (`quality = 2`).
- **Seraphim Familiar (ID 390)**: Automatically credits progression towards the Seraphim transformation (3/3 grants holy flight).

## Compatibility & Installation

Compatible with iOS 15.0 - 17.x+ on ARM64 devices.

### A. Rootless Jailbreak (Dopamine / Palera1n / Sileo)
1. Download `IsaacRepPlusiOS-rootless.deb` from the [Releases](https://github.com/n1cknam3l3ss/IsaacRepPlusiOS/releases) page.
2. Open with Sileo / Zebra and tap **Get / Install**.
3. Launch *The Binding of Isaac*.

### B. LiveContainer (Non-Jailbroken / Sideloaded)
1. Download `IsaacRepPlusiOS-LiveContainer.framework.zip` from Releases.
2. In LiveContainer, open App Settings for *The Binding of Isaac*.
3. Tap **Add Framework** and select the downloaded zip file.
4. Launch the game.

### C. Direct IPA Injection (TrollStore / Sideloadly / Azule)
1. Download `IsaacRepPlusiOS.dylib`.
2. Inject into the Isaac IPA using Azule or Sideloadly.
3. Sign and install.

## Building from Source

Requires macOS with Xcode command-line tools:
```bash
git clone https://github.com/n1cknam3l3ss/IsaacRepPlusiOS.git
cd IsaacRepPlusiOS
make all
```

Output binaries will be placed in `build/`, `packages/`, and `dist/`.
