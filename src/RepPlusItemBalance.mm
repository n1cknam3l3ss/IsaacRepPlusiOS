#import "RepPlusItemBalance.h"
#import "RepPlusVoidPatch.h"
#import "RepPlusLogger.h"
#import "RepPlusMemory.h"

#import <objc/runtime.h>
#include <cstdint>
#include <unordered_set>

// Dynamic interface for EIDDescription so ARC and Clang know the method signatures
@interface NSObject (EIDDescriptionDynamic)
- (NSInteger)pickupVariant;
- (NSInteger)pickupSubtype;
- (NSString *)name;
- (NSString *)detail;
- (NSString *)iconPath;
- (NSInteger)quality;
- (NSInteger)itemType;
- (NSInteger)maxCharges;
- (NSInteger)chargeType;
- (instancetype)initWithPickupVariant:(NSInteger)pickupVariant
                              subtype:(NSInteger)subtype
                                 name:(NSString *)name
                               detail:(NSString *)detail
                             iconPath:(NSString *)iconPath
                              quality:(NSInteger)quality
                             itemType:(NSInteger)itemType
                           maxCharges:(NSInteger)maxCharges
                           chargeType:(NSInteger)chargeType;
@end

namespace {

// 1. Repentance Manager & ItemConfig (Active Repentance items: 0..722+)
constexpr uintptr_t kRepentanceManagerGlobalRVA = 0xAC2428;
constexpr size_t kRepentanceItemConfigOffset = 0x55F30;

// 2. AppManager & ItemConfig (Rebirth/Afterbirth+ engine items: 0..553)
constexpr uintptr_t kAppManagerGlobalRVA = 0xAC1768;
constexpr size_t kRebirthItemConfigOffset = 0x32880;

// 3. Game global & room entities
constexpr uintptr_t kGameGlobalRVA = 0xAC3B90;
constexpr size_t kGameCurrentRoomOffset = 0x21550;
constexpr size_t kRoomEntitiesArrayOffset = 0x19C8;
constexpr size_t kRoomEntitiesCountOffset = 0x19D4;

// 4. Game Functions
// CheckTransformation(void *player, int32_t itemId, int32_t arg2, int32_t arg3)
constexpr uintptr_t kCheckTransformationRVA = 0x1A46B8;
// Player::HasCollectible(void *player, int32_t itemId)
constexpr uintptr_t kHasCollectibleRVA = 0x2E58B8;

typedef void (*CheckTransformation_t)(void *player, int32_t itemId, int32_t arg2, int32_t arg3);
typedef bool (*HasCollectible_t)(void *player, int32_t itemId);

// Entity_Player field offsets
constexpr size_t kPlayerItemTableOffset = 0x29A0;
constexpr size_t kPlayerTransformationBitsOffset = 0x1E64;

// Item field offsets (identical across Repentance & Rebirth item structs)
constexpr size_t kItemFieldId = 0x04;
constexpr size_t kItemFieldSoulHearts = 0x60;
constexpr size_t kItemFieldBlackHearts = 0x64;
constexpr size_t kItemFieldMaxCharges = 0x74;
constexpr size_t kItemFieldQuality = 0xC8;
constexpr size_t kItemFieldCraftQuality = 0xCC;

static bool g_appliedRepentancePatches = false;
static bool g_appliedRebirthPatches = false;
static uint32_t g_periodicVerifyCounter = 0;
static std::unordered_set<uintptr_t> g_seraphimCreditedPlayers;

// Helper to write an item field safely with direct assignment fallback
static bool WriteItemField32(uintptr_t itemAddr, size_t offset, int32_t newVal, const char *fieldName, size_t itemId) {
    if (!itemAddr) return false;
    uintptr_t targetAddr = itemAddr + offset;
    int32_t currentVal = 0;
    if (SafeRead(targetAddr, currentVal) && currentVal == newVal) {
        return true; // Already patched
    }

    bool success = SafeWrite(targetAddr, newVal);
    if (!success) {
        @try {
            *reinterpret_cast<int32_t *>(targetAddr) = newVal;
            success = true;
        } @catch (...) {
            success = false;
        }
    }

    if (success) {
        RepPlusLog(@"Patched item %zu %s: %d -> %d", itemId, fieldName, currentVal, newVal);
    } else {
        RepPlusLog(@"Failed to patch item %zu %s (target: 0x%lx)", itemId, fieldName, (unsigned long)targetAddr);
    }
    return success;
}

static bool PatchItemsInConfig(uintptr_t itemConfigAddr, const char *configName) {
    if (!itemConfigAddr) return false;

    uintptr_t itemsBegin = 0;
    uintptr_t itemsEnd = 0;
    if (!SafeRead(itemConfigAddr + 0x0, itemsBegin) || !itemsBegin) return false;
    if (!SafeRead(itemConfigAddr + 0x8, itemsEnd) || !itemsEnd || itemsEnd <= itemsBegin) return false;

    size_t count = (itemsEnd - itemsBegin) / sizeof(uintptr_t);
    if (count < 352) return false; // Items not populated yet

    auto GetItemPtr = [&](size_t id) -> uintptr_t {
        if (id >= count) return 0;
        uintptr_t item = 0;
        if (!SafeRead(itemsBegin + id * sizeof(uintptr_t), item) || !item) return 0;
        int32_t checkId = -1;
        if (!SafeRead(item + kItemFieldId, checkId) || checkId != static_cast<int32_t>(id)) {
            return 0;
        }
        return item;
    };

    bool allApplied = true;

    // 1. Revelation (643): remove +2 soul hearts upon pickup (gives 0 soul hearts)
    if (count > 643) {
        uintptr_t revelation = GetItemPtr(643);
        if (revelation) {
            WriteItemField32(revelation, kItemFieldSoulHearts, 0, "soulhearts", 643);
        } else {
            allApplied = false;
        }
    }

    // 2. Mega Bean (351): 6 charges (Rep+ balance rework)
    uintptr_t megaBean = GetItemPtr(351);
    if (megaBean) {
        WriteItemField32(megaBean, kItemFieldMaxCharges, 6, "maxcharges", 351);
    } else {
        allApplied = false;
    }

    // 3. 2Spooky (554): Quality 2 (Rep+ buff)
    if (count > 554) {
        uintptr_t twoSpooky = GetItemPtr(554);
        if (twoSpooky) {
            WriteItemField32(twoSpooky, kItemFieldQuality, 2, "quality", 554);
            WriteItemField32(twoSpooky, kItemFieldCraftQuality, 2, "craftquality", 554);
        } else {
            allApplied = false;
        }
    }

    // Additional Rep+ ItemConfig balance improvements:
    // D12 (440): 2 charges (was 3)
    if (count > 440) {
        uintptr_t d12 = GetItemPtr(440);
        if (d12) WriteItemField32(d12, kItemFieldMaxCharges, 2, "maxcharges", 440);
    }

    // Breath of Life (326): 4 charges (was 6)
    if (count > 326) {
        uintptr_t bol = GetItemPtr(326);
        if (bol) WriteItemField32(bol, kItemFieldMaxCharges, 4, "maxcharges", 326);
    }

    // Dataminer (474): 3 charges (was 4)
    if (count > 474) {
        uintptr_t dataminer = GetItemPtr(474);
        if (dataminer) WriteItemField32(dataminer, kItemFieldMaxCharges, 3, "maxcharges", 474);
    }

    // Camo Undies (460): Quality 2 (was 1)
    if (count > 460) {
        uintptr_t camo = GetItemPtr(460);
        if (camo) {
            WriteItemField32(camo, kItemFieldQuality, 2, "quality", 460);
            WriteItemField32(camo, kItemFieldCraftQuality, 2, "craftquality", 460);
        }
    }

    // Milk! (406): Quality 2 (was 1)
    if (count > 406) {
        uintptr_t milk = GetItemPtr(406);
        if (milk) {
            WriteItemField32(milk, kItemFieldQuality, 2, "quality", 406);
            WriteItemField32(milk, kItemFieldCraftQuality, 2, "craftquality", 406);
        }
    }

    // Shade (446): Quality 2 (was 1)
    if (count > 446) {
        uintptr_t shade = GetItemPtr(446);
        if (shade) {
            WriteItemField32(shade, kItemFieldQuality, 2, "quality", 446);
            WriteItemField32(shade, kItemFieldCraftQuality, 2, "craftquality", 446);
        }
    }

    // My Shadow (429): Quality 2 (was 1)
    if (count > 429) {
        uintptr_t myShadow = GetItemPtr(429);
        if (myShadow) {
            WriteItemField32(myShadow, kItemFieldQuality, 2, "quality", 429);
            WriteItemField32(myShadow, kItemFieldCraftQuality, 2, "craftquality", 429);
        }
    }

    RepPlusLog(@"Rep+ balance patches successfully applied to %s (count: %zu)", configName, count);
    return allApplied;
}

// -----------------------------------------------------------------------------
// EID Integration (dynamically synchronizes visual Quality & Charges in EID)
// -----------------------------------------------------------------------------
static id (*s_orig_EID_descForPickup)(id, SEL, NSInteger, NSInteger) = nullptr;

static id RepPlus_EID_descForPickup(id self, SEL _cmd, NSInteger variant, NSInteger subtype) {
    id desc = s_orig_EID_descForPickup ? s_orig_EID_descForPickup(self, _cmd, variant, subtype) : nil;
    if (!desc) return nil;

    // EIDPickupVariantCollectible == 100
    if (variant == 100) {
        NSInteger targetQuality = -1;
        NSInteger targetCharges = -1;

        if (subtype == 554) targetQuality = 2; // 2Spooky -> Q2
        else if (subtype == 460) targetQuality = 2; // Camo Undies -> Q2
        else if (subtype == 406) targetQuality = 2; // Milk! -> Q2
        else if (subtype == 446) targetQuality = 2; // Shade -> Q2
        else if (subtype == 429) targetQuality = 2; // My Shadow -> Q2

        if (subtype == 351) targetCharges = 6; // Mega Bean -> 6 charges
        else if (subtype == 440) targetCharges = 2; // D12 -> 2 charges
        else if (subtype == 326) targetCharges = 4; // Breath of Life -> 4 charges
        else if (subtype == 474) targetCharges = 3; // Dataminer -> 3 charges

        if (targetQuality != -1 || targetCharges != -1) {
            NSInteger currentQ = -1;
            NSInteger currentCh = -1;
            @try { currentQ = [desc quality]; } @catch (...) {}
            @try { currentCh = [desc maxCharges]; } @catch (...) {}

            NSInteger finalQ = (targetQuality != -1) ? targetQuality : currentQ;
            NSInteger finalCh = (targetCharges != -1) ? targetCharges : currentCh;

            if (finalQ != currentQ || finalCh != currentCh) {
                Class descClass = NSClassFromString(@"EIDDescription");
                if (descClass) {
                    return [[descClass alloc] initWithPickupVariant:variant
                                                            subtype:subtype
                                                               name:[desc name]
                                                             detail:[desc detail]
                                                           iconPath:[desc iconPath]
                                                            quality:finalQ
                                                           itemType:[desc itemType]
                                                         maxCharges:finalCh
                                                         chargeType:[desc chargeType]];
                }
            }
        }
    }
    return desc;
}

static void InstallEIDHookIfNeeded(void) {
    static dispatch_once_t onceToken;
    Class storeClass = NSClassFromString(@"EIDDescriptionStore");
    if (!storeClass) return;

    dispatch_once(&onceToken, ^{
        SEL sel = @selector(descriptionForPickupVariant:subtype:);
        Method m = class_getInstanceMethod(storeClass, sel);
        if (m) {
            s_orig_EID_descForPickup = reinterpret_cast<id (*)(id, SEL, NSInteger, NSInteger)>(method_getImplementation(m));
            method_setImplementation(m, reinterpret_cast<IMP>(RepPlus_EID_descForPickup));
            RepPlusLog(@"Installed EIDDescriptionStore hook: Rep+ Quality & Charges now displayed in EID overlay!");
        }
    });
}

} // namespace

void RepPlusApplyItemBalancePatches(void) {
    uintptr_t base = RepPlusGetBaseAddress();
    if (!base) return;

    // 1. Repentance ItemConfig (active Repentance items, including Revelation, 2Spooky, etc.)
    if (!g_appliedRepentancePatches) {
        uintptr_t repManager = 0;
        if (SafeRead(base + kRepentanceManagerGlobalRVA, repManager) && repManager) {
            uintptr_t repItemConfig = repManager + kRepentanceItemConfigOffset;
            if (PatchItemsInConfig(repItemConfig, "Repentance ItemConfig")) {
                g_appliedRepentancePatches = true;
            }
        }
    }

    // 2. Rebirth/Afterbirth+ ItemConfig (legacy engine structures)
    if (!g_appliedRebirthPatches) {
        uintptr_t appManager = 0;
        if (SafeRead(base + kAppManagerGlobalRVA, appManager) && appManager) {
            uintptr_t rebItemConfig = appManager + kRebirthItemConfigOffset;
            if (PatchItemsInConfig(rebItemConfig, "Rebirth ItemConfig")) {
                g_appliedRebirthPatches = true;
            }
        }
    }

    // 3. EID visual overlay hook
    InstallEIDHookIfNeeded();
}

void RepPlusPlayerBalanceTick(void) {
    uintptr_t base = RepPlusGetBaseAddress();
    if (!base) return;

    // Apply or re-verify item configs
    if (!g_appliedRepentancePatches || !g_appliedRebirthPatches) {
        RepPlusApplyItemBalancePatches();
    } else {
        // Periodic verification every ~5 seconds (33 ticks * 0.15s) in case game reloaded items
        if (++g_periodicVerifyCounter >= 33) {
            g_periodicVerifyCounter = 0;
            uintptr_t repManager = 0;
            if (SafeRead(base + kRepentanceManagerGlobalRVA, repManager) && repManager) {
                uintptr_t repItemConfig = repManager + kRepentanceItemConfigOffset;
                PatchItemsInConfig(repItemConfig, "Repentance ItemConfig (periodic check)");
            }
        }
    }

    // Attempt EID hook if loaded later
    InstallEIDHookIfNeeded();

    uintptr_t game = 0;
    if (!SafeRead(base + kGameGlobalRVA, game) || !game) return;

    uintptr_t room = 0;
    if (!SafeRead(game + kGameCurrentRoomOffset, room) || !room) return;

    uintptr_t entitiesArrayPtr = 0;
    int32_t count = 0;
    if (!SafeRead(room + kRoomEntitiesArrayOffset, entitiesArrayPtr) || !entitiesArrayPtr) return;
    if (!SafeRead(room + kRoomEntitiesCountOffset, count) || count <= 0 || count > 2048) return;

    HasCollectible_t HasCollectible = reinterpret_cast<HasCollectible_t>(base + kHasCollectibleRVA);
    CheckTransformation_t CheckTransformation = reinterpret_cast<CheckTransformation_t>(base + kCheckTransformationRVA);

    for (int32_t i = 0; i < count; ++i) {
        uintptr_t entity = 0;
        if (!SafeRead(entitiesArrayPtr + i * sizeof(uintptr_t), entity) || !entity) continue;

        int32_t type = 0;
        if (!SafeRead(entity + 0x38, type)) continue;

        // Entity_Player is type 1
        if (type == 1) {
            void *player = reinterpret_cast<void *>(entity);
            uintptr_t playerAddr = entity;

            // Check if player has item 390 (Seraphim Familiar)
            bool hasSeraphim = false;
            if (HasCollectible) {
                hasSeraphim = HasCollectible(player, 390);
            } else {
                uintptr_t table = 0;
                if (SafeRead(playerAddr + kPlayerItemTableOffset, table) && table) {
                    uint8_t cnt = 0;
                    if (SafeRead(table + 390, cnt) && cnt > 0) {
                        hasSeraphim = true;
                    }
                }
            }

            if (hasSeraphim) {
                if (g_seraphimCreditedPlayers.find(playerAddr) == g_seraphimCreditedPlayers.end()) {
                    // Check if player already completed Seraphim transformation (bit 0x80)
                    uint32_t transformBits = 0;
                    SafeRead(playerAddr + kPlayerTransformationBitsOffset, transformBits);

                    if ((transformBits & 0x80) == 0 && CheckTransformation) {
                        // Advance Seraphim transformation by 1 natively via The Halo (101) logic
                        CheckTransformation(player, 101, 0, 1);
                        RepPlusLog(@"Credited Seraphim familiar (390) towards Seraphim transformation for player %p", player);
                    }

                    g_seraphimCreditedPlayers.insert(playerAddr);
                }
            } else {
                // Remove if player no longer has 390 (run restart or reroll)
                g_seraphimCreditedPlayers.erase(playerAddr);
            }
        }
    }
}
