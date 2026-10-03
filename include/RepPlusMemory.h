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
    if (kr != KERN_SUCCESS) {
        vm_size_t pageSize = vm_page_size ? vm_page_size : 16384;
        vm_address_t page = address & ~(pageSize - 1);
        vm_size_t protectSize = ((address + sizeof(T) + pageSize - 1) & ~(pageSize - 1)) - page;
        vm_protect(mach_task_self(), page, protectSize, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        kr = vm_write(mach_task_self(),
                      static_cast<vm_address_t>(address),
                      reinterpret_cast<vm_offset_t>(&val),
                      sizeof(T));
    }
    return (kr == KERN_SUCCESS);
}
