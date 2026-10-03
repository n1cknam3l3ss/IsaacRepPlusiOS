#pragma once

#import <Foundation/Foundation.h>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

/// Resolves the base memory address of Isaac executable/dylib in the process
uintptr_t RepPlusGetBaseAddress(void);

/// Check if Isaac executable is verified and ready
bool RepPlusIsSupportedBuild(uintptr_t *outBase);

/// Periodic check called from main thread watchdog
void RepPlusVoidWatchdogTick(void);

#ifdef __cplusplus
}
#endif
