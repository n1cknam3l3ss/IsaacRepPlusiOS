#import "RepPlusBootstrap.h"
#import "RepPlusVoidPatch.h"
#import "RepPlusItemBalance.h"
#import "RepPlusLogger.h"

#import <UIKit/UIKit.h>

static dispatch_once_t g_startOnce;
static NSTimer *g_watchdogTimer = nil;

void RepPlusStart(void) {
    dispatch_once(&g_startOnce, ^{
        intptr_t slide = 0;
        if (!RepPlusIsSupportedBuild(&slide)) {
            RepPlusLog(@"Unsupported or non-Isaac executable image detected; skipping Rep+ initialization.");
            return;
        }

        RepPlusLog(@"Initializing IsaacRepPlusiOS tweak (slide: 0x%lx)", (unsigned long)slide);

        // 1. Install native hooks if ElleKit / Substrate runtime hooker is available
        RepPlusInstallVoidHooks();

        // 2. Start repeating timer for guaranteed Void portal and balance tracking
        g_watchdogTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                          repeats:YES
                                                            block:^(NSTimer * _Nonnull timer) {
            @autoreleasepool {
                RepPlusVoidWatchdogTick();
                RepPlusPlayerBalanceTick();
            }
        }];
        [[NSRunLoop mainRunLoop] addTimer:g_watchdogTimer forMode:NSRunLoopCommonModes];

        RepPlusLog(@"IsaacRepPlusiOS active! Guaranteed Void portals & Rep+ item balance enabled.");
    });
}

__attribute__((constructor)) static void RepPlusConstructor(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:UIApplicationDidBecomeActiveNotification
                                object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(__unused NSNotification *note) { RepPlusStart(); }];

            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                RepPlusStart();
            }
        });
    }
}
