#pragma once

#import <mach/mach.h>
#import <mach/vm_map.h>
#include <cstdint>

template <typename T>
inline bool SafeRead(uintptr_t address, T &outVal) {
    if (!address) return false;
    vm_size_t copied = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         static_cast<vm_address_t>(address),
                                         sizeof(T),
                                         reinterpret_cast<vm_address_t>(&outVal),
                                         &copied);
    return (kr == KERN_SUCCESS && copied == sizeof(T));
}

template <typename T>
inline bool SafeWrite(uintptr_t address, const T &val) {
    if (!address) return false;
    kern_return_t kr = vm_write(mach_task_self(),
                                static_cast<vm_address_t>(address),
                                reinterpret_cast<vm_offset_t>(&val),
                                sizeof(T));
    return (kr == KERN_SUCCESS);
}
