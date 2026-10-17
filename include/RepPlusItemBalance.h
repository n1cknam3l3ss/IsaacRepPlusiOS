#pragma once

#import <Foundation/Foundation.h>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/// Applies in-memory item config adjustments (Revelation, Mega Bean, 2Spooky, Seraphim, etc.)
void RepPlusApplyItemBalancePatches(void);

/// Periodic player check (e.g. Seraphim transformation progression, stat updates)
void RepPlusPlayerBalanceTick(void);

#ifdef __cplusplus
}
#endif
