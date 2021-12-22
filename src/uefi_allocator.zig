const std = @import("std");

const mem = std.mem;
const uefi = std.os.uefi;

const Allocator = mem.Allocator;

pub const allocator = Allocator{
    .ptr = undefined,
    .vtable = &allocator_table,
};

pub const allocator_table = Allocator.VTable{
    .alloc = uefi_alloc,
    .resize = uefi_resize,
    .free = uefi_free,
};

fn uefi_alloc(
    _: *anyopaque,
    len: usize,
    ptr_align: u29,
    len_align: u29,
    ret_addr: usize,
) Allocator.Error![]u8 {
    _ = len_align;
    _ = ret_addr;

    std.debug.assert(ptr_align <= 8);

    var ptr: [*]align(8) u8 = undefined;

    if (uefi.system_table.boot_services.?.allocatePool(.BootServicesData, len, &ptr) != .Success) {
        return error.OutOfMemory;
    }

    return ptr[0..len];
}

fn uefi_resize(
    _: *anyopaque,
    buf: []u8,
    old_align: u29,
    new_len: usize,
    len_align: u29,
    ret_addr: usize,
) ?usize {
    _ = old_align;
    _ = ret_addr;

    if (new_len == 0) {
        uefi_free(undefined, buf, old_align, ret_addr);
        // _ = uefi.system_table.boot_services.?.freePool(@alignCast(8, buf.ptr));
        return 0;
    }

    if (new_len <= buf.len) {
        return mem.alignAllocLen(buf.len, new_len, len_align);
    }

    return null;
}

fn uefi_free(
    _: *anyopaque,
    buf: []u8,
    old_align: u29,
    ret_addr: usize,
) void {
    _ = old_align;
    _ = ret_addr;

    std.debug.assert(old_align == 8);

    _ = uefi.system_table.boot_services.?.freePool(@alignCast(8, buf.ptr));
}
