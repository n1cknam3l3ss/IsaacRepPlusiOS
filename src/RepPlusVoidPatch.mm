#import "RepPlusVoidPatch.h"
#import "RepPlusLogger.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#include <vector>

namespace {

constexpr const char *kSupportedUUID = "F4357753-A25F-30EE-BACF-63709F902895";

constexpr uintptr_t kGameGlobalRVA = 0xAC3B90;
constexpr size_t kGameCurrentRoomOffset = 0x21550;

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
constexpr uintptr_t kRoomSpawnClearAwardsRVA = 0x59E380;
constexpr uintptr_t kBossRewardSpawnerRVA = 0x8907D8;

struct Vector2f {
    float x;
    float y;
};

typedef Vector2f (*GetCenterPos_t)(void *room);
typedef int32_t (*GetGridIndex_t)(void *room, const Vector2f *pos);
typedef void (*FindFreeTile_t)(void *room, int32_t *gridIndex);
typedef void* (*GetDefaultDesc_t)();
typedef bool (*SpawnGridEntity_t)(void *room, int32_t gridIndex, int32_t type, int32_t varIdx, void *desc, int32_t varData);

typedef void (*SpawnClearAwards_t)(void *room);
typedef void (*BossRewardSpawner_t)(void *arg0, void *arg1, uint32_t arg2, void *arg3, void *arg4, void *arg5, uint64_t arg6, uint32_t arg7);

static SpawnClearAwards_t g_origSpawnClearAwards = nullptr;
static BossRewardSpawner_t g_origBossRewardSpawner = nullptr;

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

static const mach_header_64 *FindIsaacHeader(intptr_t *slideOut) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const mach_header_64 *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        NSString *uuid = UUIDForHeader(header);
        if ([uuid caseInsensitiveCompare:[NSString stringWithUTF8String:kSupportedUUID]] == NSOrderedSame) {
            if (slideOut) *slideOut = _dyld_get_image_vmaddr_slide(i);
            return header;
        }
    }
    // Fallback to main executable if UUID header matches
    for (uint32_t i = 0; i < count; ++i) {
        const mach_header_64 *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        if (header && header->magic == MH_MAGIC_64 && header->filetype == MH_EXECUTE) {
            if (slideOut) *slideOut = _dyld_get_image_vmaddr_slide(i);
            return header;
        }
    }
    if (slideOut) *slideOut = 0;
    return nullptr;
}

} // namespace

bool RepPlusIsSupportedBuild(intptr_t *outSlide) {
    intptr_t slide = 0;
    const mach_header_64 *header = FindIsaacHeader(&slide);
    if (!header) return false;
    NSString *uuid = UUIDForHeader(header);
    bool match = ([uuid caseInsensitiveCompare:[NSString stringWithUTF8String:kSupportedUUID]] == NSOrderedSame);
    if (match && outSlide) *outSlide = slide;
    return match;
}

static bool HasVoidPortal(void *room, intptr_t slide) {
    if (!room) return false;
    uintptr_t trapDoorVTable = slide + kTrapDoorVTableRVA;
    void **gridEntities = reinterpret_cast<void **>((char *)room + kRoomGridEntitiesOffset);
    if (!gridEntities) return false;

    for (size_t i = 0; i < kRoomGridEntityCount; ++i) {
        void *ent = gridEntities[i];
        if (ent) {
            uintptr_t vtable = *reinterpret_cast<uintptr_t *>(ent);
            if (vtable == trapDoorVTable) {
                int32_t varData = *reinterpret_cast<int32_t *>((char *)ent + 0x1C);
                if (varData == 1) {
                    return true;
                }
            }
        }
    }
    return false;
}

static bool IsBossDefeated(void *room) {
    if (!room) return false;

    // Check entity list for Big Chest (Pickup 5.340) or Trophy (5.370)
    void **entitiesArray = *reinterpret_cast<void ***>((char *)room + kRoomEntitiesArrayOffset);
    int32_t count = *reinterpret_cast<int32_t *>((char *)room + kRoomEntitiesCountOffset);

    bool foundEndingChest = false;
    bool hasAliveBoss = false;

    if (entitiesArray && count > 0 && count < 2048) {
        for (int32_t i = 0; i < count; ++i) {
            void *entity = entitiesArray[i];
            if (!entity) continue;

            int32_t type = *reinterpret_cast<int32_t *>((char *)entity + 0x38);
            int32_t variant = *reinterpret_cast<int32_t *>((char *)entity + 0x3C);
            uint8_t isDead = *reinterpret_cast<uint8_t *>((char *)entity + 0x1C3);

            // Pickup (5): Big Chest (340) or Trophy (370)
            if (type == 5 && (variant == 340 || variant == 370)) {
                foundEndingChest = true;
            }

            // Boss NPC (type >= 10 && < 1000):
            // Check if active alive enemy
            if (type >= 10 && type < 1000 && !isDead) {
                float hp = *reinterpret_cast<float *>((char *)entity + 0x354);
                if (hp > 0.0f) {
                    hasAliveBoss = true;
                }
            }
        }
    }

    if (foundEndingChest) return true;
    if (!hasAliveBoss && count >= 0) return true;

    return false;
}

static void SpawnVoidPortal(void *room, intptr_t slide) {
    if (!room) return;

    GetCenterPos_t GetCenterPos = reinterpret_cast<GetCenterPos_t>(slide + kRoomGetCenterPosRVA);
    GetGridIndex_t GetGridIndex = reinterpret_cast<GetGridIndex_t>(slide + kRoomGetGridIndexRVA);
    FindFreeTile_t FindFreeTile = reinterpret_cast<FindFreeTile_t>(slide + kRoomFindFreeTileRVA);
    GetDefaultDesc_t GetDefaultDesc = reinterpret_cast<GetDefaultDesc_t>(slide + kGetDefaultDescRVA);
    SpawnGridEntity_t SpawnGridEntity = reinterpret_cast<SpawnGridEntity_t>(slide + kRoomSpawnGridEntityRVA);

    Vector2f center = GetCenterPos(room);
    int32_t gridIdx = GetGridIndex(room, &center);
    FindFreeTile(room, &gridIdx);
    void *desc = GetDefaultDesc();

    // Type 17 = TrapDoor, VarData 1 = Void Portal
    bool ok = SpawnGridEntity(room, gridIdx, 17, 0, desc, 1);
    RepPlusLog(@"Spawned guaranteed Void Portal at tile %d (success: %d)", gridIdx, (int)ok);
}

static void CheckAndSpawnVoidPortal(void *game, void *room, intptr_t slide) {
    if (!game || !room) return;

    int32_t stage = *reinterpret_cast<int32_t *>((char *)game + 0x0);
    int32_t stageType = *reinterpret_cast<int32_t *>((char *)game + 0x4);

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

    // Check room type:
    // In Isaac, RoomDescriptorData + 0x8 has RoomType: 5 is ROOM_BOSS
    int32_t roomType = 0;
    void *descriptor = *reinterpret_cast<void **>((char *)room + kRoomDescriptorOffset);
    if (descriptor) {
        void *roomData = *reinterpret_cast<void **>((char *)descriptor + kRoomDescriptorDataOffset);
        if (roomData) {
            roomType = *reinterpret_cast<int32_t *>((char *)roomData + kRoomConfigTypeOffset);
        }
    }

    // In Stage 8 (Corpse II), must be RoomType 5 (Mother)
    if (stage == 8 && roomType != 5) return;

    // In Stage 10 or 11, boss rooms or Mega Satan room
    // If not boss room or mega satan, skip
    if ((stage == 10 || stage == 11) && roomType != 5 && roomType != 22) {
        // Double-check if big chest is in the room
        void **entitiesArray = *reinterpret_cast<void ***>((char *)room + kRoomEntitiesArrayOffset);
        int32_t count = *reinterpret_cast<int32_t *>((char *)room + kRoomEntitiesCountOffset);
        bool hasEndingChest = false;
        if (entitiesArray && count > 0 && count < 2048) {
            for (int32_t i = 0; i < count; ++i) {
                void *e = entitiesArray[i];
                if (e) {
                    int32_t t = *reinterpret_cast<int32_t *>((char *)e + 0x38);
                    int32_t v = *reinterpret_cast<int32_t *>((char *)e + 0x3C);
                    if (t == 5 && (v == 340 || v == 370)) {
                        hasEndingChest = true;
                        break;
                    }
                }
            }
        }
        if (!hasEndingChest) return;
    }

    // Check if Void Portal is already present
    if (HasVoidPortal(room, slide)) return;

    // Check if the boss has been defeated
    if (!IsBossDefeated(room)) return;

    // Conditions verified: spawn guaranteed Void Portal!
    RepPlusLog(@"Guaranteed Void Portal condition met! Stage: %d, StageType: %d, RoomType: %d",
               stage, stageType, roomType);
    SpawnVoidPortal(room, slide);
}

void RepPlusVoidWatchdogTick(void) {
    intptr_t slide = 0;
    if (!RepPlusIsSupportedBuild(&slide)) return;

    void **g_GamePtr = reinterpret_cast<void **>(slide + kGameGlobalRVA);
    if (!g_GamePtr || !*g_GamePtr) return;

    void *game = *g_GamePtr;
    void *room = *reinterpret_cast<void **>((char *)game + kGameCurrentRoomOffset);
    if (!room) return;

    CheckAndSpawnVoidPortal(game, room, slide);
}

// Hook replacements if dynamic hooking is available
static void Hooked_SpawnClearAwards(void *room) {
    if (g_origSpawnClearAwards) {
        g_origSpawnClearAwards(room);
    }
    intptr_t slide = 0;
    if (RepPlusIsSupportedBuild(&slide)) {
        void **g_GamePtr = reinterpret_cast<void **>(slide + kGameGlobalRVA);
        if (g_GamePtr && *g_GamePtr) {
            CheckAndSpawnVoidPortal(*g_GamePtr, room, slide);
        }
    }
}

static void Hooked_BossRewardSpawner(void *arg0, void *arg1, uint32_t arg2, void *arg3, void *arg4, void *arg5, uint64_t arg6, uint32_t arg7) {
    if (g_origBossRewardSpawner) {
        g_origBossRewardSpawner(arg0, arg1, arg2, arg3, arg4, arg5, arg6, arg7);
    }
    intptr_t slide = 0;
    if (RepPlusIsSupportedBuild(&slide)) {
        void **g_GamePtr = reinterpret_cast<void **>(slide + kGameGlobalRVA);
        if (g_GamePtr && *g_GamePtr) {
            void *game = *g_GamePtr;
            void *room = *reinterpret_cast<void **>((char *)game + kGameCurrentRoomOffset);
            if (room) {
                CheckAndSpawnVoidPortal(game, room, slide);
            }
        }
    }
}

void RepPlusInstallVoidHooks(void) {
    intptr_t slide = 0;
    if (!RepPlusIsSupportedBuild(&slide)) return;

    typedef void (*MSHookFunction_t)(void *symbol, void *replace, void **result);
    MSHookFunction_t MSHookFunctionPtr = reinterpret_cast<MSHookFunction_t>(dlsym(RTLD_DEFAULT, "MSHookFunction"));
    if (MSHookFunctionPtr) {
        MSHookFunctionPtr(reinterpret_cast<void *>(slide + kRoomSpawnClearAwardsRVA),
                          reinterpret_cast<void *>(Hooked_SpawnClearAwards),
                          reinterpret_cast<void **>(&g_origSpawnClearAwards));
        MSHookFunctionPtr(reinterpret_cast<void *>(slide + kBossRewardSpawnerRVA),
                          reinterpret_cast<void *>(Hooked_BossRewardSpawner),
                          reinterpret_cast<void **>(&g_origBossRewardSpawner));
        RepPlusLog(@"Installed native void hooks on SpawnClearAwards and BossRewardSpawner");
    } else {
        RepPlusLog(@"MSHookFunction unavailable; relying on main-thread watchdog timer");
    }
}
