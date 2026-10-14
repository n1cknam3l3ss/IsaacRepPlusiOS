#import "RepPlusLogger.h"
#import <Foundation/Foundation.h>
#include <fstream>
#include <mutex>

static std::mutex g_logMutex;
static std::ofstream g_logFile;

static void EnsureLogFileOpen(void) {
    if (!g_logFile.is_open()) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject;
        if (docDir) {
            NSString *logPath = [docDir stringByAppendingPathComponent:@"isaacrepplus_log.txt"];
            g_logFile.open([logPath UTF8String], std::ios::out | std::ios::app);
            if (g_logFile.is_open()) {
                g_logFile << "\n=== IsaacRepPlusiOS v1.0.13 Log Started: "
                          << [[NSDate date] description].UTF8String << " ===\n" << std::flush;
            }
        }
    }
}

void RepPlusLog(NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[IsaacRep+] %@", msg);

    std::lock_guard<std::mutex> lock(g_logMutex);
    EnsureLogFileOpen();
    if (g_logFile.is_open()) {
        g_logFile << [msg UTF8String] << "\n" << std::flush;
    }
}
