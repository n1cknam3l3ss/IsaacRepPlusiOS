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

inline bool SafeReadBytes(uintptr_t address, void *outBuf, size_t size) {
    if (!address || !outBuf || !size) return false;
    vm_size_t copied = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         static_cast<vm_address_t>(address),
                                         size,
                                         reinterpret_cast<vm_address_t>(outBuf),
                                         &copied);
    return (kr == KERN_SUCCESS && copied == size);
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

        vm_address_t regionAddr = page;
        vm_size_t regionSize = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object_name = MACH_PORT_NULL;
        vm_prot_t origProt = VM_PROT_READ | VM_PROT_WRITE;
        if (vm_region_64(mach_task_self(), &regionAddr, &regionSize, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object_name) == KERN_SUCCESS) {
            origProt = info.protection;
        }

        vm_protect(mach_task_self(), page, protectSize, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        kr = vm_write(mach_task_self(),
                      static_cast<vm_address_t>(address),
                      reinterpret_cast<vm_offset_t>(&val),
                      sizeof(T));
        if (origProt & VM_PROT_EXECUTE) {
            vm_protect(mach_task_self(), page, protectSize, FALSE, origProt);
        }
    }
    return (kr == KERN_SUCCESS);
}
