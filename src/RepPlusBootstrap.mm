#import "RepPlusBootstrap.h"
#import "RepPlusVoidPatch.h"
#import "RepPlusItemBalance.h"
#import "RepPlusLogger.h"

#import <UIKit/UIKit.h>

static BOOL g_initialized = NO;
static NSTimer *g_retryTimer = nil;
static NSTimer *g_watchdogTimer = nil;
static int g_retryAttempts = 0;

static void RepPlusTryInit(void) {
    if (g_initialized) return;

    uintptr_t base = 0;
    if (!RepPlusIsSupportedBuild(&base)) {
        if (++g_retryAttempts % 10 == 0) {
            RepPlusLog(@"Waiting for Isaac executable image to be mapped in dyld (attempt %d)...", g_retryAttempts);
        }
        return;
    }

    g_initialized = YES;
    if (g_retryTimer) {
        [g_retryTimer invalidate];
        g_retryTimer = nil;
    }

    RepPlusLog(@"Initializing IsaacRepPlusiOS tweak v1.0.17 (base: 0x%lx)", (unsigned long)base);

    // Run one-time initialization
    RepPlusVoidPatchInit(base);
    RepPlusApplyItemBalancePatches();

    // Start repeating timer for guaranteed Void portal and balance tracking
    g_watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                      repeats:YES
                                                        block:^(NSTimer * _Nonnull timer) {
        @autoreleasepool {
            RepPlusVoidWatchdogTick();
            RepPlusPlayerBalanceTick();
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:g_watchdogTimer forMode:NSRunLoopCommonModes];

    RepPlusLog(@"IsaacRepPlusiOS v1.0.17 active! Guaranteed Void portals & Rep+ balance running.");
}

void RepPlusStart(void) {
    RepPlusTryInit();
}

__attribute__((constructor)) static void RepPlusConstructor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            RepPlusTryInit();
            if (!g_initialized) {
                // Poll every 250ms until Isaac executable is mapped
                g_retryTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
                    RepPlusTryInit();
                }];
            }
        });
    }
}
