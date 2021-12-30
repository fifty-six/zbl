const std = @import("std");
const uefi = std.os.uefi;

const protocols = uefi.protocols;

const menus = @import("menu.zig");
const output = @import("output.zig");
const move = @import("move.zig");
const text = @import("text.zig");
const device_path = @import("device_path.zig");
const uefi_alloc = @import("uefi_allocator.zig");
const fs_info = @import("fs_info.zig");

const Allocator = std.mem.Allocator;

const Status = uefi.Status;

const Output = output.Output;

const Menu = menus.Menu;
const MenuEntry = menus.MenuEntry;

const FileInfo = protocols.FileInfo;
const FileProtocol = protocols.FileProtocol;
const SimpleFileSystemProtocol = protocols.SimpleFileSystemProtocol;
const DevicePathProtocol = protocols.DevicePathProtocol;
const FileSystemInfo = fs_info.FileSystemInfo;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

var sys_table: *uefi.tables.SystemTable = undefined;
var boot_services: *uefi.tables.BootServices = undefined;
var con_in: *protocols.SimpleTextInputProtocol = undefined;
var con_out: *protocols.SimpleTextOutputProtocol = undefined;
var out: Output = undefined;

var heap_alloc_state: std.heap.ArenaAllocator = undefined;
var heap_alloc: Allocator = undefined;

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

    file_name: [:0]const u16,
    disk_info: DiskInfo,

    pub fn load_callback(ptr: ?*align(8) const anyopaque) void {
        if (ptr == null) {
            unreachable;
        }

        @ptrCast(*const Loader, ptr.?).load() catch |e| {
            out.printf("{s}\r\n", .{@errorName(e)}) catch return;
            return;
        };
    }

    pub fn load(self: *const Self) !void {
        var img: ?uefi.Handle = undefined;

        var image_path = try device_path.file_path(heap_alloc, self.disk_info.disk, self.file_name);
        var res = boot_services.loadImage(false, uefi.handle, image_path, null, 0, &img);

        if (res != .Success) {
            try out.printf("{s}\r\n", .{@tagName(res)});
            return error.ImageLoadFailure;
        }

        var img_proto = try open_protocol(img.?, protocols.LoadedImageProtocol);
        img_proto.load_options = null;
        img_proto.load_options_size = 0;

        if (boot_services.startImage(img.?, null, null) != .Success) {
            return error.ImageStartFailure;
        }
    }
};

pub const DiskInfo = struct {
    disk: *DevicePathProtocol,
    disk_name: [:0]const u16,
};

pub fn join_paths(alloc: Allocator, prefix: [:0]const u16, suffix: [:0]const u16) ![:0]const u16 {
    var res: []u16 = try alloc.alloc(u16, prefix.len + 1 + suffix.len + 1);
    res[res.len - 1] = 0;

    std.mem.copy(u16, res[0..prefix.len], prefix);
    std.mem.copy(u16, res[prefix.len .. prefix.len + 1], utf16_str("\\"));
    std.mem.copy(u16, res[prefix.len + 1 .. res.len], suffix);

    return res[0 .. res.len - 1 :0];
}

pub fn scan_dir(fp: *const FileProtocol, buf: []align(8) u8) !?[:0]const u16 {
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

        var file_info = @ptrCast(*FileInfo, buf.ptr);

        var fname = std.mem.span(file_info.getFileName());

        if (!std.mem.endsWith(u16, fname, utf16_str(".efi")) and !std.mem.endsWith(u16, fname, utf16_str(".EFI")))
            continue;

        // macOS uses "._fname" for storing extended attributes on non-HFS+ filesystems.
        if (std.mem.startsWith(u16, fname, utf16_str("._")))
            continue;

        return fname;
    }

    return null;
}

const Directory = struct {
    file_info: *FileInfo,
    dir_name: [:0]const u16,
    handle: *const FileProtocol,

    pub fn deinit(self: *const Directory) void {
        _ = self.handle.close();
    }
};

pub fn next_dir(fp: *const FileProtocol, buf: []align(8) u8) !?Directory {
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

        var file_info = @ptrCast(*FileInfo, buf.ptr);

        var fname = std.mem.span(file_info.getFileName());

        if (std.mem.eql(u16, fname, utf16_str("..")) or std.mem.eql(u16, fname, utf16_str(".")))
            continue;

        if ((file_info.attribute & FileInfo.efi_file_directory) != 0) {
            var handle: *const FileProtocol = undefined;

            if (fp.open(
                &handle,
                file_info.getFileName(),
                FileProtocol.efi_file_mode_read,
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

pub fn scan_efi(
    alloc: Allocator,
    li: *std.ArrayList(Loader),
    fp: *const FileProtocol,
    disk_info: DiskInfo,
    buf: []align(8) u8,
) !void {
    var efi: *const FileProtocol = undefined;
    var res = fp.open(&efi, utf16_str("EFI"), FileProtocol.efi_file_mode_read, 0);

    if (res != .Success) {
        return;
    }

    const efi_str = utf16_str("EFI");

    while (try next_dir(efi, buf)) |dir| {
        // NOTE:
        // dir.name and dir.file_info point into the buffer
        // so copy them out before re-using buffer.
        defer dir.deinit();

        // Copy out the path with the prefix, as it's in the buffer which will be cleared.
        var base_path = try join_paths(alloc, efi_str, dir.dir_name);
        defer alloc.free(base_path);

        while (try scan_dir(dir.handle, buf)) |fname| {
            var name = try join_paths(alloc, base_path, fname);

            try out.print16(name.ptr);
            try out.print("\r\n");

            try li.append(Loader{
                .disk_info = disk_info,
                .file_name = name,
            });
        }
    }
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
        &SimpleFileSystemProtocol.guid,
        null,
        &res_size,
        &handle_ptr,
    ) != .Success) {
        return error.EnumerateHandleFailure;
    }

    heap_alloc_state = std.heap.ArenaAllocator.init(uefi_alloc.allocator);
    heap_alloc = heap_alloc_state.allocator();

    var alloc = heap_alloc;

    var handles = handle_ptr[0..res_size];
    var loaders = std.ArrayList(Loader).init(heap_alloc);

    var buf: [1024]u8 align(8) = undefined;
    for (handles) |handle| {
        var sfsp = try open_protocol(handle, SimpleFileSystemProtocol);
        var device = try open_protocol(handle, DevicePathProtocol);

        var fp: *const protocols.FileProtocol = undefined;

        if (sfsp.openVolume(&fp) != .Success)
            return error.UnableToOpenVolume;

        var size = buf.len;

        if (fp.getInfo(&FileSystemInfo.guid, &size, &buf) != .Success)
            return error.UnableToGetInfo;

        var info = @ptrCast(*FileSystemInfo, &buf);
        var label = info.getVolumeLabel();

        var disk_info = DiskInfo{
            .disk = device,
            // Have to dupe the label as its from the buffer, which we'll overwrite.
            .disk_name = try alloc.dupeZ(u16, std.mem.span(label)),
        };

        while (try scan_dir(fp, &buf)) |fname| {
            var name = try alloc.dupeZ(u16, fname);

            try out.print16(name.ptr);
            try out.print("\r\n");

            try loaders.append(Loader{
                .disk_info = disk_info,
                .file_name = name,
            });
        }

        try scan_efi(heap_alloc, &loaders, fp, disk_info, &buf);
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
    });

    for (loaders.items) |*entry| {
        var desc = try std.mem.concat(heap_alloc, u16, &[_][]const u16{
            entry.disk_info.disk_name,
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

    try entries.append(MenuEntry{
        .description = utf16_str("Exit"),
        .callback = .{ .Empty = die_fast },
        .data = null,
    });

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
