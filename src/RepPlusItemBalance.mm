#import "RepPlusItemBalance.h"
#import "RepPlusVoidPatch.h"
#import "RepPlusLogger.h"

#include <cstdint>
#include <unordered_set>

namespace {

constexpr uintptr_t kAppManagerGlobalRVA = 0xAC1768;
constexpr size_t kItemConfigOffset = 0x32880;

constexpr uintptr_t kGameGlobalRVA = 0xAC3B90;
constexpr size_t kGameCurrentRoomOffset = 0x21550;
constexpr size_t kRoomEntitiesArrayOffset = 0x19C8;
constexpr size_t kRoomEntitiesCountOffset = 0x19D4;

constexpr size_t kPlayerCollectibleCountsOffset = 0x1ab8;
constexpr size_t kPlayerTransformationCountersOffset = 0x1c54;
constexpr size_t kPlayerCanFlyOffset = 0x1954;
constexpr size_t kMaximumCollectibleID = 732;

static bool g_appliedItemConfigPatches = false;
static std::unordered_set<uintptr_t> g_seraphimCreditedPlayers;

static void* GetItemConfig(intptr_t slide) {
    void **appPtr = reinterpret_cast<void **>(slide + kAppManagerGlobalRVA);
    if (!appPtr || !*appPtr) return nullptr;
    return reinterpret_cast<void *>((char *)(*appPtr) + kItemConfigOffset);
}

} // namespace

void RepPlusApplyItemBalancePatches(void) {
    if (g_appliedItemConfigPatches) return;

    intptr_t slide = 0;
    if (!RepPlusIsSupportedBuild(&slide)) return;

    void *itemConfig = GetItemConfig(slide);
    if (!itemConfig) return;

    void **items = *reinterpret_cast<void ***>((char *)itemConfig + 0x0);
    void **itemsEnd = *reinterpret_cast<void ***>((char *)itemConfig + 0x8);
    if (!items || !itemsEnd || items >= itemsEnd) return;

    size_t count = itemsEnd - items;
    if (count < 650) return; // Not fully loaded yet

    // 1. Revelation (643): remove +2 soul hearts upon pickup
    if (643 < count && items[643]) {
        int32_t *soulHearts = reinterpret_cast<int32_t *>((char *)items[643] + 0x60);
        *soulHearts = 0;
        RepPlusLog(@"Patched Item 643 (Revelation): soulhearts = 0 (Rep+ balance)");
    }

    // 2. Mega Bean (351): 6 charges
    if (351 < count && items[351]) {
        int32_t *maxCharges = reinterpret_cast<int32_t *>((char *)items[351] + 0x74);
        *maxCharges = 6;
        RepPlusLog(@"Patched Item 351 (Mega Bean): maxcharges = 6 (Rep+ rework)");
    }

    // 3. 2Spooky (554): Quality 2
    if (554 < count && items[554]) {
        int32_t *quality = reinterpret_cast<int32_t *>((char *)items[554] + 0xC8);
        *quality = 2;
        RepPlusLog(@"Patched Item 554 (2Spooky): quality = 2 (Rep+ buff)");
    }

    g_appliedItemConfigPatches = true;
    RepPlusLog(@"Rep+ item balance patches successfully applied to ItemConfig");
}

void RepPlusPlayerBalanceTick(void) {
    intptr_t slide = 0;
    if (!RepPlusIsSupportedBuild(&slide)) return;

    // First ensure ItemConfig is patched
    if (!g_appliedItemConfigPatches) {
        RepPlusApplyItemBalancePatches();
    }

    void **g_GamePtr = reinterpret_cast<void **>(slide + kGameGlobalRVA);
    if (!g_GamePtr || !*g_GamePtr) return;

    void *game = *g_GamePtr;
    void *room = *reinterpret_cast<void **>((char *)game + kGameCurrentRoomOffset);
    if (!room) return;

    void **entitiesArray = *reinterpret_cast<void ***>((char *)room + kRoomEntitiesArrayOffset);
    int32_t count = *reinterpret_cast<int32_t *>((char *)room + kRoomEntitiesCountOffset);
    if (!entitiesArray || count <= 0 || count > 2048) return;

    for (int32_t i = 0; i < count; ++i) {
        void *entity = entitiesArray[i];
        if (!entity) continue;

        int32_t type = *reinterpret_cast<int32_t *>((char *)entity + 0x38);
        // Entity_Player is type 1
        if (type == 1) {
            uintptr_t playerAddr = reinterpret_cast<uintptr_t>(entity);
            int32_t *collectibles = reinterpret_cast<int32_t *>((char *)entity + kPlayerCollectibleCountsOffset);
            int32_t *transforms = reinterpret_cast<int32_t *>((char *)entity + kPlayerTransformationCountersOffset);

            // Rep+ Seraphim: Item 390 (Seraphim Familiar) contributes to Seraphim transformation (index 3)
            int32_t seraphimCount = collectibles[390];
            if (seraphimCount > 0 && g_seraphimCreditedPlayers.find(playerAddr) == g_seraphimCreditedPlayers.end()) {
                transforms[3] += 1;
                g_seraphimCreditedPlayers.insert(playerAddr);
                RepPlusLog(@"Credited Seraphim familiar (390) towards Seraphim transformation for player %p (current: %d/3)",
                           entity, transforms[3]);

                if (transforms[3] >= 3) {
                    *reinterpret_cast<uint8_t *>((char *)entity + kPlayerCanFlyOffset) = 1;
                    RepPlusLog(@"Player %p completed Seraphim transformation! Granted flight.", entity);
                }
            }
        }
    }
}
