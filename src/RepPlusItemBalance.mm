#import "RepPlusItemBalance.h"
#import "RepPlusVoidPatch.h"
#import "RepPlusLogger.h"
#import "RepPlusMemory.h"

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

static uintptr_t GetItemConfigAddr(uintptr_t base) {
    uintptr_t appManagerPtr = 0;
    if (!SafeRead(base + kAppManagerGlobalRVA, appManagerPtr) || !appManagerPtr) return 0;
    return appManagerPtr + kItemConfigOffset;
}

} // namespace

void RepPlusApplyItemBalancePatches(void) {
    if (g_appliedItemConfigPatches) return;

    uintptr_t base = RepPlusGetBaseAddress();
    if (!base) return;

    uintptr_t itemConfig = GetItemConfigAddr(base);
    if (!itemConfig) return;

    uintptr_t itemsBegin = 0;
    uintptr_t itemsEnd = 0;
    if (!SafeRead(itemConfig + 0x0, itemsBegin) || !itemsBegin) return;
    if (!SafeRead(itemConfig + 0x8, itemsEnd) || !itemsEnd || itemsEnd <= itemsBegin) return;

    size_t count = (itemsEnd - itemsBegin) / sizeof(uintptr_t);
    if (count < 650) return; // Not fully loaded yet

    // Helper to read item pointer
    auto GetItemPtr = [&](size_t id) -> uintptr_t {
        if (id >= count) return 0;
        uintptr_t item = 0;
        SafeRead(itemsBegin + id * sizeof(uintptr_t), item);
        return item;
    };

    // 1. Revelation (643): remove +2 soul hearts upon pickup
    uintptr_t revelation = GetItemPtr(643);
    if (revelation) {
        int32_t zero = 0;
        SafeWrite(revelation + 0x60, zero);
        RepPlusLog(@"Patched Item 643 (Revelation): soulhearts = 0 (Rep+ balance)");
    }

    // 2. Mega Bean (351): 6 charges
    uintptr_t megaBean = GetItemPtr(351);
    if (megaBean) {
        int32_t six = 6;
        SafeWrite(megaBean + 0x74, six);
        RepPlusLog(@"Patched Item 351 (Mega Bean): maxcharges = 6 (Rep+ rework)");
    }

    // 3. 2Spooky (554): Quality 2
    uintptr_t twoSpooky = GetItemPtr(554);
    if (twoSpooky) {
        int32_t two = 2;
        SafeWrite(twoSpooky + 0xC8, two);
        RepPlusLog(@"Patched Item 554 (2Spooky): quality = 2 (Rep+ buff)");
    }

    g_appliedItemConfigPatches = true;
    RepPlusLog(@"Rep+ item balance patches successfully applied to ItemConfig");
}

void RepPlusPlayerBalanceTick(void) {
    uintptr_t base = RepPlusGetBaseAddress();
    if (!base) return;

    if (!g_appliedItemConfigPatches) {
        RepPlusApplyItemBalancePatches();
    }

    uintptr_t game = 0;
    if (!SafeRead(base + kGameGlobalRVA, game) || !game) return;

    uintptr_t room = 0;
    if (!SafeRead(game + kGameCurrentRoomOffset, room) || !room) return;

    uintptr_t entitiesArrayPtr = 0;
    int32_t count = 0;
    if (!SafeRead(room + kRoomEntitiesArrayOffset, entitiesArrayPtr) || !entitiesArrayPtr) return;
    if (!SafeRead(room + kRoomEntitiesCountOffset, count) || count <= 0 || count > 2048) return;

    for (int32_t i = 0; i < count; ++i) {
        uintptr_t entity = 0;
        if (!SafeRead(entitiesArrayPtr + i * sizeof(uintptr_t), entity) || !entity) continue;

        int32_t type = 0;
        if (!SafeRead(entity + 0x38, type)) continue;

        // Entity_Player is type 1
        if (type == 1) {
            uintptr_t playerAddr = entity;

            // Rep+ Seraphim: Item 390 (Seraphim Familiar) contributes to Seraphim transformation (index 3)
            int32_t seraphimCount = 0;
            if (SafeRead(playerAddr + kPlayerCollectibleCountsOffset + 390 * sizeof(int32_t), seraphimCount) &&
                seraphimCount > 0 &&
                g_seraphimCreditedPlayers.find(playerAddr) == g_seraphimCreditedPlayers.end()) {
                
                int32_t currentProgress = 0;
                uintptr_t transformSlotAddr = playerAddr + kPlayerTransformationCountersOffset + 3 * sizeof(int32_t);
                SafeRead(transformSlotAddr, currentProgress);
                currentProgress += 1;
                SafeWrite(transformSlotAddr, currentProgress);

                g_seraphimCreditedPlayers.insert(playerAddr);
                RepPlusLog(@"Credited Seraphim familiar (390) towards Seraphim transformation for player 0x%lx (current: %d/3)",
                           (unsigned long)playerAddr, currentProgress);

                if (currentProgress >= 3) {
                    uint8_t canFly = 1;
                    SafeWrite(playerAddr + kPlayerCanFlyOffset, canFly);
                    RepPlusLog(@"Player 0x%lx completed Seraphim transformation! Granted flight.", (unsigned long)playerAddr);
                }
            }
        }
    }
}
