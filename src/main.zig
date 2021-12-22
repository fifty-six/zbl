const std = @import("std");
const uefi = std.os.uefi;

const protocols = uefi.protocols;
const Status = uefi.Status;

const menus = @import("menu.zig");
const output = @import("output.zig");
const move = @import("move.zig");
const text = @import("text.zig");
const device_path = @import("device_path.zig");
const uefi_alloc = @import("uefi_allocator.zig");

const Output = output.Output;

const Menu = menus.Menu;
const MenuEntry = menus.MenuEntry;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

var alloc_bytes: [100 * 1024]u8 = undefined;
var alloc_state = std.heap.FixedBufferAllocator.init(&alloc_bytes);
const fixed_alloc = alloc_state.allocator();

var sys_table: *uefi.tables.SystemTable = undefined;
var boot_services: *uefi.tables.BootServices = undefined;
var con_in: *protocols.SimpleTextInputProtocol = undefined;
var con_out: *protocols.SimpleTextOutputProtocol = undefined;
pub var out: Output = undefined;

var heap_alloc_state: std.heap.ArenaAllocator = undefined;
var heap_alloc: std.mem.Allocator = undefined;

pub fn open_protocol(handle: uefi.Handle, comptime protocol: type) !*protocol {
    var ptr: *protocol = undefined;
    if (boot_services.openProtocol(
        handle,
        &protocol.guid,
        @ptrCast(*?*anyopaque, &ptr),
        uefi.handle,
        null,
        uefi.tables.OpenProtocolAttributes{ .by_handle_protocol = true },
    ) != .Success) {
        return error.FailedToOpenProtocol;
    }

    return ptr;
}

pub const Loader = struct {
    const Self = @This();

    size: usize,
    disk: *protocols.DevicePathProtocol,

    disk_name: [:0]const u16,
    file_name: [:0]const u16,

    pub fn load_callback(ptr: ?*align(8) const anyopaque) void {
        if (ptr == null) {
            unreachable;
        }

        @ptrCast(*const Loader, ptr.?).load() catch unreachable;
    }

    pub fn load(self: *const Self) !void {
        var img: ?uefi.Handle = undefined;

        var disk = try device_path.file_path(heap_alloc, self.disk, self.file_name);
        var res = boot_services.loadImage(false, uefi.handle, disk, null, 0, &img);

        if (res != .Success) {
            try out.printf("{s}\r\n", .{@tagName(res)});
            return error.ImageLoadFailure;
        }

        var img_proto = open_protocol(img.?, protocols.LoadedImageProtocol) catch |e| {
            try out.printf("{s}\r\n", .{@errorName(e)});
            return;
        };

        img_proto.load_options = null;
        img_proto.load_options_size = 0;

        if (boot_services.startImage(img.?, null, null) != .Success) {
            try out.printf("{s}\r\n", .{@tagName(res)});
            return error.ImageStartFailure;
        }
    }
};

pub fn scan_dir(
    alloc: std.mem.Allocator,
    li: *std.ArrayList(Loader),
    fp: *const protocols.FileProtocol,
    dp: *protocols.DevicePathProtocol,
    base_dir: [:0]const u16,
    disk_name: [:0]const u16,
) !void {
    var buf: [1024]u8 align(8) = undefined;
    var size = buf.len;

    _ = dp;

    while (true) {
        size = buf.len;

        switch (fp.read(&size, &buf)) {
            .Success => {},
            .BufferTooSmall => return error.BufferTooSmall,
            else => return error.DiskError,
        }

        if (size == 0)
            break;

        var file_info = @ptrCast(*protocols.FileInfo, &buf);

        var fname = std.mem.span(file_info.getFileName());

        if (std.mem.endsWith(u16, fname, utf16_str(".efi")) or std.mem.endsWith(u16, fname, utf16_str(".EFI"))) {
            // macOS uses "._fname" for storing extended attributes on non-HFS+ filesystems.
            if (std.mem.startsWith(u16, fname, utf16_str("._")))
                continue;

            var name: []u16 = try alloc.alloc(u16, base_dir.len + 1 + fname.len + 1);
            name[name.len - 1] = 0;

            std.mem.copy(u16, name[0..base_dir.len], base_dir);
            std.mem.copy(u16, name[base_dir.len .. base_dir.len + 1], utf16_str("\\"));
            std.mem.copy(u16, name[base_dir.len + 1 .. name.len], fname);

            try out.print16(name[0 .. name.len - 1 :0].ptr);

            try li.append(Loader{
                .disk = dp,
                .size = file_info.file_size,
                .file_name = name[0 .. name.len - 1 :0],
                .disk_name = disk_name,
            });
        }
    }
}

const Directory = struct {
    file_info: *protocols.FileInfo,
    dir_name: [:0]const u16,
    handle: *const protocols.FileProtocol,
};

pub fn next_dir(fp: *const protocols.FileProtocol, buf: []align(8) u8) !?Directory {
    var size = buf.len;

    while (true) {
        size = buf.len;

        switch (fp.read(&size, buf.ptr)) {
            .Success => {},
            .BufferTooSmall => return error.BufferTooSmall,
            else => return error.DiskError,
        }

        if (size == 0)
            break;

        var file_info = @ptrCast(*protocols.FileInfo, buf.ptr);

        var fname = std.mem.span(file_info.getFileName());

        if (std.mem.eql(u16, fname, utf16_str("..")) or std.mem.eql(u16, fname, utf16_str(".")))
            continue;

        if ((file_info.attribute & protocols.FileInfo.efi_file_directory) != 0) {
            var handle: *const protocols.FileProtocol = undefined;

            if (fp.open(
                &handle,
                file_info.getFileName(),
                protocols.FileProtocol.efi_file_mode_read,
                0,
            ) != .Success) {
                return error.DiskError;
            }

            return Directory{
                .file_info = file_info,
                .dir_name = fname,
                .handle = handle,
            };
        }
    }

    return null;
}

pub fn main() void {
    caught_main() catch unreachable;
}

pub fn caught_main() !void {
    sys_table = uefi.system_table;
    boot_services = sys_table.boot_services.?;
    con_out = sys_table.con_out.?;
    con_in = sys_table.con_in.?;
    out = Output{ .con = con_out };

    try out.reset(false);

    var handle_ptr: [*]uefi.Handle = undefined;
    var res_size: usize = undefined;

    if (boot_services.locateHandleBuffer(
        .ByProtocol,
        &protocols.SimpleFileSystemProtocol.guid,
        null,
        &res_size,
        &handle_ptr,
    ) != .Success) {
        return error.EnumerateHandleFailure;
    }

    heap_alloc_state = std.heap.ArenaAllocator.init(uefi_alloc.allocator);
    heap_alloc = heap_alloc_state.allocator();

    var handles = handle_ptr[0..res_size];

    var loaders = std.ArrayList(Loader).init(heap_alloc);

    for (handles) |handle| {
        var sfsp = try open_protocol(handle, protocols.SimpleFileSystemProtocol);
        var device = try open_protocol(handle, protocols.DevicePathProtocol);

        var fp: *const protocols.FileProtocol = undefined;

        if (sfsp.openVolume(&fp) != .Success)
            return error.UnableToOpenVolume;

        var str_path = try device_path.to_str(heap_alloc, device);

        try scan_dir(heap_alloc, &loaders, fp, device, utf16_str(""), str_path);

        var efi: *const protocols.FileProtocol = undefined;
        var res = fp.open(&efi, utf16_str("EFI"), protocols.FileProtocol.efi_file_mode_read, 0);

        if (res != .Success) {
            continue;
        }

        var buf: [1024]u8 align(8) = undefined;
        while (try next_dir(efi, &buf)) |dir| {
            var base_path = try heap_alloc.alloc(u16, 5 + dir.dir_name.len + 1);
            var efi_str = utf16_str("\\EFI\\");

            std.mem.copy(u16, base_path[0..efi_str.len], efi_str);
            std.mem.copy(u16, base_path[efi_str.len .. base_path.len - 1], dir.dir_name);
            base_path[base_path.len - 1] = 0;

            try scan_dir(heap_alloc, &loaders, dir.handle, device, base_path[0 .. base_path.len - 1 :0], str_path);

            _ = dir.handle.close();
        }
    }

    var entries = std.ArrayList(MenuEntry).init(heap_alloc);

    try entries.appendSlice(&[_]MenuEntry{
        MenuEntry{
            .description = utf16_str("Move the cursor"),
            .callback = .{ .Empty = move.move },
            .data = null,
        },
        MenuEntry{
            .description = utf16_str("Write some text"),
            .callback = .{ .Empty = text.text },
            .data = null,
        },
        MenuEntry{
            .description = utf16_str("Exit"),
            .callback = .{ .Empty = die_fast },
            .data = null,
        },
    });

    for (loaders.items) |*entry| {
        var desc = try std.mem.concat(heap_alloc, u16, &[_][]const u16{
            entry.disk_name,
            utf16_str(": "),
            entry.file_name,
            &[_]u16{0},
        });

        try entries.append(MenuEntry{
            .description = desc[0 .. desc.len - 1 :0],
            .callback = .{ .WithData = Loader.load_callback },
            .data = &(entry.*),
        });
    }

    try out.reset(false);

    var menu = Menu.init(entries.items, out, con_in);

    var entry = try menu.run();

    switch (entry.callback) {
        .WithData => |fun| {
            fun(entry.data);
        },
        .Empty => |fun| {
            fun();
        },
    }

    unreachable;
}

const f_panic = @import("panic.zig");
pub fn panic(message: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
    f_panic.panic(message, trace);
}

pub fn die_fast() noreturn {
    f_panic.die(.Success);
}
