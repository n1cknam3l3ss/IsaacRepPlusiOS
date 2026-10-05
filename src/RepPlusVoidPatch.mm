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

constexpr size_t kRoomDescriptorOffset = 0x8;
constexpr size_t kRoomDescriptorDataOffset = 0x10;
constexpr size_t kRoomConfigTypeOffset = 0x8;

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
constexpr uintptr_t kGetCutsceneEventRVA = 0x6D4CB8;

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
typedef void* (*GetCutsceneEvent_t)(void *game, int32_t eventId, int32_t subId);

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
    // Fallback to main executable if UUID header matches
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
static bool g_seenMegaSatanPhase2 = false;
static bool g_seenMotherPhase2 = false;
static int32_t g_guaranteedPortalGridIdx = -1;
static uint32_t g_chestDropDelayTicks = 0;
constexpr uint32_t kChestDropDelayTicks = 8; // ~1.2s delay (8 * 0.15s ticks) matching chest drop landing
static bool g_spawnedGuaranteedPortal = false;

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

static void RemoveNaturalVoidPortals(uintptr_t roomAddr, uintptr_t base, int32_t allowedGridIdx) {
    if (!roomAddr || !base) return;
    uintptr_t trapDoorVTable = base + kTrapDoorVTableRVA;
    uintptr_t gridEntitiesAddr = roomAddr + kRoomGridEntitiesOffset;

    uintptr_t gridEntities[kRoomGridEntityCount] = {0};
    if (!SafeReadBytes(gridEntitiesAddr, gridEntities, sizeof(gridEntities))) return;

    for (size_t i = 0; i < kRoomGridEntityCount; ++i) {
        uintptr_t entPtr = gridEntities[i];
        if (!entPtr) continue;

        uintptr_t vtable = 0;
        if (!SafeRead(entPtr, vtable)) continue;

        if (vtable == trapDoorVTable) {
            int32_t varData = 0;
            if (SafeRead(entPtr + 0x1C, varData) && varData == 1) {
                // If this portal is not our guaranteed portal, destroy and remove it!
                if (allowedGridIdx < 0 || static_cast<int32_t>(i) != allowedGridIdx) {
                    uintptr_t dtorAddr = 0;
                    if (SafeRead(vtable + 8, dtorAddr) && dtorAddr) {
                        typedef void (*Dtor_t)(void *);
                        Dtor_t dtor = reinterpret_cast<Dtor_t>(dtorAddr);
                        @try { dtor(reinterpret_cast<void *>(entPtr)); } @catch (...) {}
                    }
                    uintptr_t zero = 0;
                    SafeWrite(gridEntitiesAddr + i * sizeof(uintptr_t), zero);
                    RepPlusLog(@"Removed natural/duplicate Void Portal at tile %zu (allowed tile: %d)", i, allowedGridIdx);
                }
            }
        }
    }
}

static bool CheckBossAndChestState(uintptr_t roomAddr, int32_t roomType, int32_t stage, int32_t stageType, bool &outHasChest) {
    if (!roomAddr) return false;

    uintptr_t entitiesArrayPtr = 0;
    int32_t count = 0;
    if (!SafeRead(roomAddr + kRoomEntitiesArrayOffset, entitiesArrayPtr) || !entitiesArrayPtr) return false;
    if (!SafeRead(roomAddr + kRoomEntitiesCountOffset, count) || count <= 0 || count > 2048) return false;

    bool foundEndingChest = false;
    bool hasAliveBoss = false;

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
                foundEndingChest = true;
            } else if (variant == 370 && stage == 8 && stageType == 4) {
                foundEndingChest = true; // Mother Trophy in Corpse II
            }
        }

        // Track Mega Satan: Type 275 is Mega Satan Phase 2
        if (roomType == 22 && type == 275) {
            g_seenMegaSatanPhase2 = true;
        }

        // Track Mother: Type 912, Variant >= 10 is Mother Phase 2
        if (stage == 8 && stageType == 4 && type == 912 && variant >= 10) {
            g_seenMotherPhase2 = true;
        }

        // Check if boss NPC is alive
        if (type >= 10 && type < 1000 && !isDead) {
            float hp = 0.0f;
            if (SafeRead(entity + 0x354, hp) && hp > 0.0f) {
                hasAliveBoss = true;
            }
        }
    }

    outHasChest = foundEndingChest;

    // Mega Satan room (roomType 22):
    // Fight is NEVER over during Phase 1. Must have reached Phase 2 and defeated it!
    if (roomType == 22) {
        if (!g_seenMegaSatanPhase2) return false;
        if (hasAliveBoss) return false;
        return true;
    }

    // Mother room (Corpse II):
    // Fight is NEVER over during Phase 1. Must have reached Phase 2 and defeated it (or trophy present)!
    if (stage == 8 && stageType == 4) {
        if (!g_seenMotherPhase2 && !foundEndingChest) return false;
        if (hasAliveBoss) return false;
        return true;
    }

    // Blue Baby (Chest) / The Lamb (Dark Room):
    if (foundEndingChest) return true;
    if (!hasAliveBoss) return true;

    return false;
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

static void SpawnBigChest(uintptr_t gameAddr, void *room, uintptr_t base) {
    if (!gameAddr || !room || !base) return;

    GetCenterPos_t GetCenterPos = reinterpret_cast<GetCenterPos_t>(base + kRoomGetCenterPosRVA);
    GameSpawn_t GameSpawn = reinterpret_cast<GameSpawn_t>(base + kGameSpawnEntityRVA);

    Vector2f center = GetCenterPos(room);
    Vector2f zeroVel = {0.0f, 0.0f};

    void *chest = GameSpawn(reinterpret_cast<void *>(gameAddr), 5, 340, &center, &zeroVel, nullptr, 0, 1);
    RepPlusLog(@"Spawned Big Chest (5.340) in Mega Satan room (ptr: 0x%lx)", (unsigned long)chest);
}

static void SuppressMegaSatanCutscene(uintptr_t gameAddr, uintptr_t base) {
    if (!gameAddr || !base) return;
    GetCutsceneEvent_t GetCutsceneEvent = reinterpret_cast<GetCutsceneEvent_t>(base + kGetCutsceneEventRVA);
    void *event = GetCutsceneEvent(reinterpret_cast<void *>(gameAddr), -11, -1);
    if (event) {
        uintptr_t activeCutscene = 0;
        SafeRead(reinterpret_cast<uintptr_t>(event) + 0x10, activeCutscene);
        if (!activeCutscene) {
            uintptr_t sentinel = 1;
            SafeWrite(reinterpret_cast<uintptr_t>(event) + 0x10, sentinel);
            RepPlusLog(@"Suppressed automatic Mega Satan Ending 16 cutscene (player free to enter Void Portal or Big Chest)");
        }
    }
}

static void CheckAndSpawnVoidPortal(uintptr_t gameAddr, uintptr_t roomAddr, uintptr_t base) {
    if (!gameAddr || !roomAddr || !base) return;

    // Room tracking: reset state when moving to a new room
    if (roomAddr != g_currentRoomAddr) {
        g_currentRoomAddr = roomAddr;
        g_seenMegaSatanPhase2 = false;
        g_seenMotherPhase2 = false;
        g_guaranteedPortalGridIdx = -1;
        g_chestDropDelayTicks = 0;
        g_spawnedGuaranteedPortal = false;
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

    int32_t roomType = 0;
    uintptr_t descriptor = 0;
    if (SafeRead(roomAddr + kRoomDescriptorOffset, descriptor) && descriptor) {
        uintptr_t roomData = 0;
        if (SafeRead(descriptor + kRoomDescriptorDataOffset, roomData) && roomData) {
            SafeRead(roomData + kRoomConfigTypeOffset, roomType);
        }
    }

    // In Stage 8 (Corpse II), must be RoomType 5 (Mother)
    if (stage == 8 && roomType != 5) return;

    // In Stage 10 or 11, check for boss room (5) or Mega Satan room (22)
    if ((stage == 10 || stage == 11) && roomType != 5 && roomType != 22) {
        return;
    }

    // Do not spawn Void Portals in Challenges or Daily runs
    int32_t challengeId = 0;
    if (SafeRead(gameAddr + kGameChallengeOffset, challengeId) && challengeId != 0) {
        RemoveNaturalVoidPortals(roomAddr, base, -1);
        return;
    }

    int32_t dailyChallenge = 0;
    if (SafeRead(gameAddr + kGameDailyChallengeOffset, dailyChallenge) && dailyChallenge != 0) {
        RemoveNaturalVoidPortals(roomAddr, base, -1);
        return;
    }

    bool hasChest = false;
    bool bossDefeated = CheckBossAndChestState(roomAddr, roomType, stage, stageType, hasChest);
    if (!bossDefeated) {
        // Boss fight is still ongoing (Phase 1, transition, or Phase 2)
        // Clean up any rogue natural portals
        RemoveNaturalVoidPortals(roomAddr, base, g_guaranteedPortalGridIdx);
        return;
    }

    // Mega Satan room handling:
    if (roomType == 22) {
        // Suppress automatic Ending 16 cutscene now that Phase 2 is defeated
        SuppressMegaSatanCutscene(gameAddr, base);

        // Ensure Big Chest is spawned in Mega Satan room if not yet present
        if (!hasChest) {
            SpawnBigChest(gameAddr, reinterpret_cast<void *>(roomAddr), base);
            hasChest = true;
        }
    }

    // If guaranteed portal was already spawned in this room:
    if (g_spawnedGuaranteedPortal) {
        // Keep our portal, remove any duplicate/natural portals that aren't at our target tile
        RemoveNaturalVoidPortals(roomAddr, base, g_guaranteedPortalGridIdx);
        return;
    }

    // Boss was defeated, but guaranteed portal has not yet spawned.
    // Suppress/destroy any vanilla natural portal that spawned prematurely!
    RemoveNaturalVoidPortals(roomAddr, base, -1);

    // Visual polish delay: wait for the chest/trophy drop animation to finish landing (~1.2s = 8 ticks)
    if (hasChest) {
        if (++g_chestDropDelayTicks < kChestDropDelayTicks) {
            return; // Still waiting for chest to fall and hit the floor
        }
    }

    // Conditions verified & chest has landed: calculate target tile and spawn guaranteed Void Portal!
    GetCenterPos_t GetCenterPos = reinterpret_cast<GetCenterPos_t>(base + kRoomGetCenterPosRVA);
    GetGridIndex_t GetGridIndex = reinterpret_cast<GetGridIndex_t>(base + kRoomGetGridIndexRVA);
    FindFreeTile_t FindFreeTile = reinterpret_cast<FindFreeTile_t>(base + kRoomFindFreeTileRVA);

    Vector2f pos = GetCenterPos(reinterpret_cast<void *>(roomAddr));
    pos.y += 80.0f; // 2 tiles down so portal does not overlap the chest
    int32_t targetGridIdx = GetGridIndex(reinterpret_cast<void *>(roomAddr), &pos);
    FindFreeTile(reinterpret_cast<void *>(roomAddr), &targetGridIdx);

    RepPlusLog(@"Spawning guaranteed Void Portal after victory! Stage: %d, RoomType: %d, Tile: %d",
               stage, roomType, targetGridIdx);
    int32_t spawnedIdx = SpawnVoidPortal(reinterpret_cast<void *>(roomAddr), base);
    g_guaranteedPortalGridIdx = (spawnedIdx >= 0) ? spawnedIdx : targetGridIdx;
    g_spawnedGuaranteedPortal = true;

    // Clean up any other portals
    RemoveNaturalVoidPortals(roomAddr, base, g_guaranteedPortalGridIdx);
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
