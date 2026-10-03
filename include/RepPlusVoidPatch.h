#pragma once

#import <Foundation/Foundation.h>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/// Check if Isaac executable is verified and ready
bool RepPlusIsSupportedBuild(intptr_t *outSlide);

/// Periodic check called from main thread watchdog
void RepPlusVoidWatchdogTick(void);

#ifdef __cplusplus
}
#endif
