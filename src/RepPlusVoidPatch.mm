#import "RepPlusVoidPatch.h"
#import "RepPlusLogger.h"
#import "RepPlusMemory.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <vector>

namespace {

constexpr const char *kSupportedUUID = "F4357753-A25F-30EE-BACF-63709F902895";

constexpr uintptr_t kGameGlobalRVA = 0xAC3B90;
constexpr size_t kGameCurrentRoomOffset = 0x21550;
constexpr size_t kGameChallengeOffset = 0x1CF438;
constexpr size_t kGameDailyChallengeOffset = 0x1CF4C0;

// Game engine cutscene & Void portal state flags:
// 1. Bit 0 of game + 0x1CF406 is m_VoidPortalSpawned in Mega Satan's room.
//    Native function 0x1006d8c34 checks (game + 0x1CF406) & 1.
//    When set to 1, the death handler (0x1005026e4) skips starting the automatic cutscene timer.
constexpr size_t kGameVoidSpawnedFlagOffset = 0x1CF406;

// 2. game + 0x2A5930 is the 89-frame countdown timer for automatic Mega Satan Ending 16 cutscene.
//    In Game::Update (0x10088e27c), when timer >= 1, it increments to 89 and starts cutscene sequence 5.
constexpr size_t kGameMegaSatanTimerOffset = 0x2A5930;

// 3. game + 0x25C00 is the active CutsceneSequence object state. (0 = idle/inactive).
constexpr size_t kGameCutsceneSeqStateOffset = 0x25C00;

constexpr size_t kRoomDescriptorOffset = 0x8;
constexpr size_t kRoomDescriptorDataOffset = 0x10;
constexpr size_t kRoomConfigTypeOffset = 0x8;
constexpr size_t kRoomConfigVariantOffset = 0x10;

constexpr size_t kRoomGridEntitiesOffset = 0x30;
constexpr size_t kRoomGridEntityCount = 448;

constexpr size_t kRoomEntitiesArrayOffset = 0x19C8;
constexpr size_t kRoomEntitiesCountOffset = 0x19D4;

constexpr uintptr_t kTrapDoorVTableRVA = 0xA8E650;

constexpr uintptr_t kRoomGetCenterPosRVA = 0x59E2AC;
constexpr uintptr_t kRoomGetGridIndexRVA = 0x5A18AC;
constexpr uintptr_t kRoomFindFreeTileRVA = 0x5AB878;
constexpr uintptr_t kGetDefaultDescRVA = 0x7F1CC0;
constexpr uintptr_t kRoomSpawnGridEntityRVA = 0x59ABC4;
constexpr uintptr_t kGameSpawnEntityRVA = 0x88FCBC;

constexpr uintptr_t kManagerGlobalRVA = 0xAC2428;
constexpr size_t kManagerPersistentDataOffset = 0x204D0;
constexpr size_t kManagerQueuedCutsceneValidOffset = 0x1F6D08;
constexpr size_t kManagerQueuedCutsceneIdOffset = 0x1F6D0C;
constexpr uintptr_t kPersistentDataUnlockedRVA = 0x7027F8;
constexpr int32_t kAchievementTheVoid = 320;

struct Vector2f {
    float x;
    float y;
};

typedef Vector2f (*GetCenterPos_t)(void *room);
typedef int32_t (*GetGridIndex_t)(void *room, const Vector2f *pos);
typedef void (*FindFreeTile_t)(void *room, int32_t *gridIndex);
typedef void* (*GetDefaultDesc_t)();
typedef bool (*SpawnGridEntity_t)(void *room, int32_t gridIndex, int32_t type, int32_t varIdx, void *desc, int32_t varData);
typedef void* (*GameSpawn_t)(void *game, int32_t type, int32_t variant, const Vector2f *pos, const Vector2f *velocity, void *spawner, int32_t subType, uint32_t seed);
typedef bool (*PersistentDataUnlocked_t)(void *persistentData, int32_t achievementId);

static NSString *UUIDForHeader(const mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"";
    const uint8_t *cursor = reinterpret_cast<const uint8_t *>(header + 1);
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        const load_command *cmd = reinterpret_cast<const load_command *>(cursor);
        if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(uuid_command)) {
            const uuid_command *ucmd = reinterpret_cast<const uuid_command *>(cursor);
            const unsigned char *u = ucmd->uuid;
            return [NSString stringWithFormat:
                    @"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]];
        }
        cursor += cmd->cmdsize;
    }
    return @"";
}

static const mach_header_64 *FindIsaacHeader(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const mach_header_64 *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        NSString *uuid = UUIDForHeader(header);
        if ([uuid caseInsensitiveCompare:[NSString stringWithUTF8String:kSupportedUUID]] == NSOrderedSame) {
            return header;
        }
    }
    for (uint32_t i = 0; i < count; ++i) {
        const mach_header_64 *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        if (header && header->magic == MH_MAGIC_64 && header->filetype == MH_EXECUTE) {
            return header;
        }
    }
    return nullptr;
}

} // namespace

uintptr_t RepPlusGetBaseAddress(void) {
    const mach_header_64 *header = FindIsaacHeader();
    return reinterpret_cast<uintptr_t>(header);
}

bool RepPlusIsSupportedBuild(uintptr_t *outBase) {
    const mach_header_64 *header = FindIsaacHeader();
    if (!header) return false;
    NSString *uuid = UUIDForHeader(header);
    bool match = ([uuid caseInsensitiveCompare:[NSString stringWithUTF8String:kSupportedUUID]] == NSOrderedSame);
    if (match && outBase) *outBase = reinterpret_cast<uintptr_t>(header);
    return match;
}

static uintptr_t g_currentRoomAddr = 0;
static bool g_isMegaSatanRoom = false;
static bool g_seenMegaSatanPhase2 = false;
static bool g_megaSatanDefeated = false;
static bool g_isMotherRoom = false;
static bool g_seenMotherPhase2 = false;
static int32_t g_guaranteedPortalGridIdx = -1;
static uint32_t g_chestDropDelayTicks = 0;
constexpr uint32_t kChestDropDelayTicks = 8; // ~1.2s delay (8 * 0.15s ticks) matching chest drop landing
static bool g_spawnedGuaranteedPortal = false;
static bool g_loggedLockedVoid = false;

static bool HasVoidPortal(uintptr_t roomAddr, uintptr_t base, int32_t *outGridIdx = nullptr) {
    if (!roomAddr || !base) return false;
    uintptr_t trapDoorVTable = base + kTrapDoorVTableRVA;
    uintptr_t gridEntitiesAddr = roomAddr + kRoomGridEntitiesOffset;

    uintptr_t gridEntities[kRoomGridEntityCount] = {0};
    if (!SafeReadBytes(gridEntitiesAddr, gridEntities, sizeof(gridEntities))) return false;

    for (size_t i = 0; i < kRoomGridEntityCount; ++i) {
        uintptr_t entPtr = gridEntities[i];
        if (!entPtr) continue;

        uintptr_t vtable = 0;
        if (!SafeRead(entPtr, vtable)) continue;

        if (vtable == trapDoorVTable) {
            int32_t varData = 0;
            if (SafeRead(entPtr + 0x1C, varData) && varData == 1) {
                if (outGridIdx) *outGridIdx = static_cast<int32_t>(i);
                return true;
            }
        }
    }
    return false;
}

static void RemoveDuplicateVoidPortals(uintptr_t roomAddr, uintptr_t base, int32_t keepGridIdx) {
    if (!roomAddr || !base) return;
    uintptr_t trapDoorVTable = base + kTrapDoorVTableRVA;
    uintptr_t gridEntitiesAddr = roomAddr + kRoomGridEntitiesOffset;

    uintptr_t gridEntities[kRoomGridEntityCount] = {0};
    if (!SafeReadBytes(gridEntitiesAddr, gridEntities, sizeof(gridEntities))) return;

    for (size_t i = 0; i < kRoomGridEntityCount; ++i) {
        if (keepGridIdx >= 0 && static_cast<int32_t>(i) == keepGridIdx) continue;
        uintptr_t entPtr = gridEntities[i];
        if (!entPtr) continue;

        uintptr_t vtable = 0;
        if (!SafeRead(entPtr, vtable)) continue;

        if (vtable == trapDoorVTable) {
            int32_t varData = 0;
            if (SafeRead(entPtr + 0x1C, varData) && varData == 1) {
                uintptr_t dtorAddr = 0;
                if (SafeRead(vtable + 8, dtorAddr) && dtorAddr) {
                    typedef void (*Dtor_t)(void *);
                    Dtor_t dtor = reinterpret_cast<Dtor_t>(dtorAddr);
                    @try { dtor(reinterpret_cast<void *>(entPtr)); } @catch (...) {}
                }
                uintptr_t zero = 0;
                SafeWrite(gridEntitiesAddr + i * sizeof(uintptr_t), zero);
                RepPlusLog(@"Removed Void Portal at tile %zu (kept tile: %d)", i, keepGridIdx);
            }
        }
    }
}

void RepPlusVoidPatchInit(uintptr_t base) {
    if (!base) return;
    RepPlusLog(@"RepPlusVoidPatch initialized in pure data-only mode (base: 0x%lx)", (unsigned long)base);
}

static bool IsVoidUnlocked(uintptr_t base) {
    if (!base) return false;
    uintptr_t managerPtrAddr = base + kManagerGlobalRVA;
    uintptr_t manager = 0;
    if (!SafeRead(managerPtrAddr, manager) || !manager) return false;

    uintptr_t persistentData = manager + kManagerPersistentDataOffset;

    // 1. Direct memory check:
    // Achievement array in PersistentGameData starts at offset 0x28.
    // Index 320 is at persistentData + 0x28 + 320 = persistentData + 0x168.
    uint8_t unlockedByte = 0;
    if (SafeRead(persistentData + 0x28 + kAchievementTheVoid, unlockedByte) && unlockedByte != 0) {
        return true;
    }

    // 2. Query native engine function (handles special unlock flags / debug):
    PersistentDataUnlocked_t Unlocked = reinterpret_cast<PersistentDataUnlocked_t>(base + kPersistentDataUnlockedRVA);
    @try {
        return Unlocked(reinterpret_cast<void *>(persistentData), kAchievementTheVoid);
    } @catch (...) {
        return false;
    }
}

static int32_t SpawnVoidPortal(void *room, uintptr_t base) {
    if (!room || !base) return -1;

    GetCenterPos_t GetCenterPos = reinterpret_cast<GetCenterPos_t>(base + kRoomGetCenterPosRVA);
    GetGridIndex_t GetGridIndex = reinterpret_cast<GetGridIndex_t>(base + kRoomGetGridIndexRVA);
    FindFreeTile_t FindFreeTile = reinterpret_cast<FindFreeTile_t>(base + kRoomFindFreeTileRVA);
    GetDefaultDesc_t GetDefaultDesc = reinterpret_cast<GetDefaultDesc_t>(base + kGetDefaultDescRVA);
    SpawnGridEntity_t SpawnGridEntity = reinterpret_cast<SpawnGridEntity_t>(base + kRoomSpawnGridEntityRVA);

    Vector2f pos = GetCenterPos(room);
    pos.y += 80.0f; // 2 tiles down so portal does not overlap the chest
    int32_t gridIdx = GetGridIndex(room, &pos);
    FindFreeTile(room, &gridIdx);
    void *desc = GetDefaultDesc();

    // Type 17 = TrapDoor, VarData 1 = Void Portal
    bool ok = SpawnGridEntity(room, gridIdx, 17, 0, desc, 1);
    RepPlusLog(@"Spawned guaranteed Void Portal at tile %d (success: %d)", gridIdx, (int)ok);
    return ok ? gridIdx : -1;
}

static void SuppressMegaSatanCutsceneTimers(uintptr_t gameAddr, uintptr_t base, bool chestTouched) {
    if (!gameAddr || !base) return;

    // 1. Set engine VoidPortalSpawned bit flag (game + 0x1CF406 |= 1).
    // Native function 0x1006d8c34 reads (game + 0x1CF406) & 1.
    // When bit 0 is set, the death handler (0x1005026e4) skips calling 0x100896ed8,
    // so the 89-frame countdown timer is never even started.
    uint8_t voidSpawned = 0;
    if (SafeRead(gameAddr + kGameVoidSpawnedFlagOffset, voidSpawned)) {
        if ((voidSpawned & 1) == 0) {
            voidSpawned |= 1;
            SafeWrite(gameAddr + kGameVoidSpawnedFlagOffset, voidSpawned);
            RepPlusLog(@"Set game + 0x1CF406 |= 1 (engine Void portal flag for Mega Satan room)");
        }
    }

    // 2. Clear the 89-frame countdown timer (game + 0x2A5930 = 0).
    // In Game::Update (0x10088e27c), if game + 0x2A5930 >= 1, it increments to 89
    // and launches Game::StartCutsceneSequence(1, 5, 0).
    int32_t msTimer = 0;
    if (SafeRead(gameAddr + kGameMegaSatanTimerOffset, msTimer) && msTimer > 0) {
        int32_t zero = 0;
        SafeWrite(gameAddr + kGameMegaSatanTimerOffset, zero);
        RepPlusLog(@"Reset Mega Satan cutscene countdown timer (was %d)", msTimer);
    }

    // 3. If player has NOT deliberately opened/touched the chest, abort cutscene sequence & manager queue:
    if (!chestTouched) {
        int32_t seqState = 0;
        if (SafeRead(gameAddr + kGameCutsceneSeqStateOffset, seqState) && seqState > 0) {
            int32_t zero = 0;
            SafeWrite(gameAddr + kGameCutsceneSeqStateOffset, zero);
            RepPlusLog(@"Cancelled CutsceneSequence state in game + 0x25C00 (was %d)", seqState);
        }

        uintptr_t manager = 0;
        if (SafeRead(base + kManagerGlobalRVA, manager) && manager) {
            uint8_t queuedValid = 0;
            int32_t queuedId = 0;
            if (SafeRead(manager + kManagerQueuedCutsceneValidOffset, queuedValid) && queuedValid != 0) {
                if (SafeRead(manager + kManagerQueuedCutsceneIdOffset, queuedId) && queuedId == 16) {
                    uint8_t zero = 0;
                    SafeWrite(manager + kManagerQueuedCutsceneValidOffset, zero);
                    RepPlusLog(@"Intercepted and cancelled queued Ending 16 cutscene in Manager!");
                }
            }
        }
    }
}

static bool CheckBossAndChestState(uintptr_t roomAddr, int32_t stage, int32_t stageType, bool &outHasChest, bool &outChestTouched) {
    if (!roomAddr) return false;

    uintptr_t entitiesArrayPtr = 0;
    int32_t count = 0;
    if (!SafeRead(roomAddr + kRoomEntitiesArrayOffset, entitiesArrayPtr) || !entitiesArrayPtr) return false;
    if (!SafeRead(roomAddr + kRoomEntitiesCountOffset, count) || count <= 0 || count > 2048) return false;

    bool foundEndingChest = false;
    bool chestWasTouched = false;
    bool hasAliveMegaSatanPhase2 = false;

    for (int32_t i = 0; i < count; ++i) {
        uintptr_t entity = 0;
        if (!SafeRead(entitiesArrayPtr + i * sizeof(uintptr_t), entity) || !entity) continue;

        int32_t type = 0;
        int32_t variant = 0;
        uint8_t isDead = 0;

        if (!SafeRead(entity + 0x38, type)) continue;
        SafeRead(entity + 0x3C, variant);
        SafeRead(entity + 0x1C3, isDead);

        // Pickup (5): Big Chest (340) or Trophy (370)
        if (type == 5) {
            if (variant == 340) {
                if (foundEndingChest && g_isMegaSatanRoom) {
                    // Clean up duplicate Big Chest in Mega Satan room
                    uint8_t dead = 1;
                    SafeWrite(entity + 0x1C3, dead);
                    RepPlusLog(@"Cleaned up duplicate Big Chest in Mega Satan room");
                } else {
                    foundEndingChest = true;
                    int32_t chestState = 0;
                    if (SafeRead(entity + 0x5B4, chestState) && chestState >= 1) {
                        chestWasTouched = true;
                    }
                }
            } else if (variant == 370 && stage == 8 && stageType == 4) {
                foundEndingChest = true; // Mother Trophy in Corpse II
                int32_t trophyState = 0;
                if (SafeRead(entity + 0x5B4, trophyState) && trophyState >= 1) {
                    chestWasTouched = true;
                }
            }
        }

        // Track Mega Satan: Type 273 (Hands), 274 (Phase 1 head), 275 (Phase 2 head)
        if (type == 273 || type == 274 || type == 275) {
            g_isMegaSatanRoom = true;
        }
        if (type == 275) {
            g_seenMegaSatanPhase2 = true;
            if (!isDead) {
                float hp = 0.0f;
                if (SafeRead(entity + 0x354, hp) && hp > 0.0f) {
                    hasAliveMegaSatanPhase2 = true;
                }
            }
        }

        // Track Mother: Type 912, Variant >= 10 is Mother Phase 2
        if (stage == 8 && stageType == 4 && type == 912) {
            g_isMotherRoom = true;
            if (variant >= 10) {
                g_seenMotherPhase2 = true;
            }
        }
    }

    outHasChest = foundEndingChest;
    outChestTouched = chestWasTouched;

    // 1. Ending Chest or Trophy is already in the room:
    if (foundEndingChest) {
        return true;
    }

    // 2. Mega Satan Room:
    if (g_isMegaSatanRoom) {
        if (g_seenMegaSatanPhase2 && !hasAliveMegaSatanPhase2) {
            g_megaSatanDefeated = true;
            return true;
        }
        return false;
    }

    // 3. Mother Room:
    if (g_isMotherRoom) {
        return foundEndingChest;
    }

    return false;
}

static void CheckAndSpawnVoidPortal(uintptr_t gameAddr, uintptr_t roomAddr, uintptr_t base) {
    if (!gameAddr || !roomAddr || !base) return;

    // Room tracking: reset state when moving to a new room
    if (roomAddr != g_currentRoomAddr) {
        g_currentRoomAddr = roomAddr;
        g_isMegaSatanRoom = false;
        g_seenMegaSatanPhase2 = false;
        g_megaSatanDefeated = false;
        g_isMotherRoom = false;
        g_seenMotherPhase2 = false;
        g_guaranteedPortalGridIdx = -1;
        g_chestDropDelayTicks = 0;
        g_spawnedGuaranteedPortal = false;
        g_loggedLockedVoid = false;
    }

    int32_t stage = 0;
    int32_t stageType = 0;
    if (!SafeRead(gameAddr + 0x0, stage)) return;
    if (!SafeRead(gameAddr + 0x4, stageType)) return;

    // Eligible boss battles:
    // 1. Mother: Stage 8, StageType 4 (Corpse II)
    // 2. Chest (Blue Baby / Mega Satan): Stage 10
    // 3. Dark Room (The Lamb / Mega Satan): Stage 11
    bool eligibleStage = false;
    if (stage == 8 && stageType == 4) {
        eligibleStage = true;
    } else if (stage == 10 || stage == 11) {
        eligibleStage = true;
    }
    if (!eligibleStage) return;

    // Room descriptor check for Mega Satan room layout:
    // RoomType 5 (Boss) and Variant 89 (0x59) in Stage 10/11
    int32_t roomType = 0;
    int32_t roomVariant = 0;
    uintptr_t descriptor = 0;
    if (SafeRead(roomAddr + kRoomDescriptorOffset, descriptor) && descriptor) {
        uintptr_t roomData = 0;
        if (SafeRead(descriptor + kRoomDescriptorDataOffset, roomData) && roomData) {
            SafeRead(roomData + kRoomConfigTypeOffset, roomType);
            SafeRead(roomData + kRoomConfigVariantOffset, roomVariant);
        }
    }
    if ((stage == 10 || stage == 11) && roomType == 5 && roomVariant == 89) {
        g_isMegaSatanRoom = true;
    }

    // Do not spawn Void Portals in Challenges or Daily runs
    int32_t challengeId = 0;
    if (SafeRead(gameAddr + kGameChallengeOffset, challengeId) && challengeId != 0) {
        return;
    }

    int32_t dailyChallenge = 0;
    if (SafeRead(gameAddr + kGameDailyChallengeOffset, dailyChallenge) && dailyChallenge != 0) {
        return;
    }

    // Check boss defeat and chest state
    bool hasChest = false;
    bool chestTouched = false;
    bool bossDefeated = CheckBossAndChestState(roomAddr, stage, stageType, hasChest, chestTouched);

    // Check if The Void is unlocked on the save file (Achievement 320: "New Area" from defeating Hush)
    bool voidUnlocked = IsVoidUnlocked(base);

    // Suppress Ending 16 cutscene if in Mega Satan room and Void is unlocked
    if (g_isMegaSatanRoom && voidUnlocked) {
        SuppressMegaSatanCutsceneTimers(gameAddr, base, chestTouched);
    }

    if (!voidUnlocked) {
        if (!g_loggedLockedVoid) {
            RepPlusLog(@"Void Portal spawn skipped: The Void is locked on this save file (Secret 320: New Area)");
            g_loggedLockedVoid = true;
        }
        // Ensure no void portals spawn or remain if The Void is locked
        RemoveDuplicateVoidPortals(roomAddr, base, -1);
        return;
    }

    // If boss is not defeated yet, wait
    if (!bossDefeated) {
        return;
    }

    // In Mega Satan room, if no chest was spawned by engine, spawn one so player can choose to end run
    if (g_isMegaSatanRoom && g_megaSatanDefeated && !hasChest) {
        GetCenterPos_t GetCenterPos = reinterpret_cast<GetCenterPos_t>(base + kRoomGetCenterPosRVA);
        GameSpawn_t GameSpawn = reinterpret_cast<GameSpawn_t>(base + kGameSpawnEntityRVA);
        Vector2f pos = GetCenterPos(reinterpret_cast<void *>(roomAddr));
        Vector2f zeroVel = {0.0f, 0.0f};
        void *chest = GameSpawn(reinterpret_cast<void *>(gameAddr), 5, 340, &pos, &zeroVel, nullptr, 0, 0);
        if (chest) {
            hasChest = true;
            RepPlusLog(@"Spawned Big Chest in Mega Satan room at (%.1f, %.1f)", pos.x, pos.y);
        }
    }

    // If Void Portal already exists in the room:
    int32_t existingPortalIdx = -1;
    if (HasVoidPortal(roomAddr, base, &existingPortalIdx)) {
        if (!g_spawnedGuaranteedPortal) {
            RepPlusLog(@"Void Portal detected at tile %d (natural or existing)", existingPortalIdx);
            g_spawnedGuaranteedPortal = true;
            g_guaranteedPortalGridIdx = existingPortalIdx;
        }
        RemoveDuplicateVoidPortals(roomAddr, base, g_guaranteedPortalGridIdx);
        return;
    }

    // If there is a chest, wait for the landing animation (~1.2s = 8 ticks)
    if (hasChest) {
        if (++g_chestDropDelayTicks < kChestDropDelayTicks) {
            return;
        }
    }

    // Chest has landed (or victory confirmed) and no portal exists yet: SPAWN GUARANTEED VOID PORTAL!
    GetCenterPos_t GetCenterPos = reinterpret_cast<GetCenterPos_t>(base + kRoomGetCenterPosRVA);
    GetGridIndex_t GetGridIndex = reinterpret_cast<GetGridIndex_t>(base + kRoomGetGridIndexRVA);
    FindFreeTile_t FindFreeTile = reinterpret_cast<FindFreeTile_t>(base + kRoomFindFreeTileRVA);

    Vector2f pos = GetCenterPos(reinterpret_cast<void *>(roomAddr));
    pos.y += 80.0f; // 2 tiles down so portal does not overlap the chest
    int32_t targetGridIdx = GetGridIndex(reinterpret_cast<void *>(roomAddr), &pos);
    FindFreeTile(reinterpret_cast<void *>(roomAddr), &targetGridIdx);

    RepPlusLog(@"Spawning guaranteed Void Portal after victory! Stage: %d, StageType: %d, TargetTile: %d",
               stage, stageType, targetGridIdx);
    int32_t spawnedIdx = SpawnVoidPortal(reinterpret_cast<void *>(roomAddr), base);
    g_guaranteedPortalGridIdx = (spawnedIdx >= 0) ? spawnedIdx : targetGridIdx;
    g_spawnedGuaranteedPortal = true;

    RemoveDuplicateVoidPortals(roomAddr, base, g_guaranteedPortalGridIdx);
}

void RepPlusVoidWatchdogTick(void) {
    uintptr_t base = RepPlusGetBaseAddress();
    if (!base) return;

    uintptr_t gamePtrAddr = base + kGameGlobalRVA;
    uintptr_t game = 0;
    if (!SafeRead(gamePtrAddr, game) || !game) return;

    uintptr_t room = 0;
    if (!SafeRead(game + kGameCurrentRoomOffset, room) || !room) return;

    CheckAndSpawnVoidPortal(game, room, base);
}
