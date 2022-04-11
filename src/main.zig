const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;

const protocols = uefi.protocols;

const menus = @import("menu.zig");
const device_path = @import("device_path.zig");
const uefi_pool_alloc = @import("uefi_pool_allocator.zig");
const fs_info = @import("fs_info.zig");
const linux = @import("linux.zig");

const Output = @import("Output.zig");

const Allocator = std.mem.Allocator;
const Status = uefi.Status;
const Menu = menus.Menu;

const FileInfo = protocols.FileInfo;
const FileProtocol = protocols.FileProtocol;
const LoadedImageProtocol = protocols.LoadedImageProtocol;
const SimpleFileSystemProtocol = protocols.SimpleFileSystemProtocol;
const DevicePathProtocol = protocols.DevicePathProtocol;
const FileSystemInfo = fs_info.FileSystemInfo;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

pub export var boot_services: *uefi.tables.BootServices = undefined;

pub var out: Output = undefined;

var sys_table: *uefi.tables.SystemTable = undefined;
var con_in: *protocols.SimpleTextInputProtocol = undefined;
var con_out: *protocols.SimpleTextOutputProtocol = undefined;

var pool_alloc_state: std.heap.ArenaAllocator = undefined;
var pool_alloc: Allocator = undefined;

const exceptions = [_][:0]const u16{
    // Windows bootloader
    utf16_str("EFI\\Microsoft\\Boot\\bootmgfw.efi"),
    // Mac bootloader
    utf16_str("System\\Library\\CoreServices\\boot.efi"),
};

pub const MenuError = error{
    GetVariableFailure,
    SetVariableFailure,
    UnknownGlyph,
    NoSpaceLeft,
    FailedToReadKey,
    InvalidUtf8,
} || Loader.LoaderError;

pub fn reboot_into_firmware() !void {
    const nonvolatile_access = 0x01;
    const bootservice_access = 0x02;
    const runtime_access = 0x04;

    const boot_to_firmware = 0x01;

    const rs = sys_table.runtime_services;
    const global_var = &uefi.tables.global_variable;

    var size: usize = @sizeOf(usize);
    var os_ind: usize = undefined;

    try rs.getVariable(utf16_str("OsIndications"), global_var, null, &size, &os_ind).err();

    if ((os_ind & boot_to_firmware) == 0) {
        var attrs: u32 = runtime_access | bootservice_access | nonvolatile_access;

        os_ind |= boot_to_firmware;

        try rs.setVariable(utf16_str("OsIndications"), global_var, attrs, @sizeOf(usize), &os_ind).err();
    }

    uefi.system_table.runtime_services.resetSystem(.ResetCold, .Success, 0, null);
}

pub const Loader = struct {
    const Self = @This();

    file_name: [:0]const u16,
    disk_info: DiskInfo,
    args: ?[:0]u16 = null,

    pub const LoaderError = error{
        OutOfMemory,
    } || Status.EfiError;

    pub fn wrapped_load(opaque_ptr: *anyopaque) LoaderError!void {
        var self = @ptrCast(*Self, @alignCast(@alignOf(Self), opaque_ptr));

        try self.load();
    }

    pub fn load(self: *const Self) LoaderError!void {
        var img: ?uefi.Handle = undefined;

        var image_path = try device_path.file_path(pool_alloc, self.disk_info.disk, self.file_name);
        try boot_services.loadImage(false, uefi.handle, image_path, null, 0, &img).err();

        var img_proto = try boot_services.openProtocolSt(LoadedImageProtocol, img.?);

        if (self.args) |options| {
            out.print("options: ") catch {};
            out.print16ln(options) catch {};

            _ = boot_services.stall(2 * 1000);

            img_proto.load_options = options.ptr;
            img_proto.load_options_size = @intCast(u32, (options.len + 1) * @sizeOf(u16));
        } else {
            img_proto.load_options = null;
            img_proto.load_options_size = 0;
        }

        try boot_services.startImage(img.?, null, null).err();
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

        try fp.read(&size, buf.ptr).err();

        if (size == 0)
            break;

        var file_info = @ptrCast(*FileInfo, buf.ptr);

        if ((file_info.attribute & FileInfo.efi_file_directory) != 0)
            continue;

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

        try fp.read(&size, buf.ptr).err();

        if (size == 0)
            break;

        var file_info = @ptrCast(*FileInfo, buf.ptr);

        var fname = std.mem.span(file_info.getFileName());

        if (std.mem.eql(u16, fname, utf16_str("..")) or std.mem.eql(u16, fname, utf16_str(".")))
            continue;

        if ((file_info.attribute & FileInfo.efi_file_directory) != 0) {
            var handle: *const FileProtocol = undefined;

            try fp.open(&handle, file_info.getFileName(), FileProtocol.efi_file_mode_read, 0).err();

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

    fp.open(&efi, utf16_str("EFI"), FileProtocol.efi_file_mode_read, 0).err() catch {
        return;
    };

    const efi_str = utf16_str("EFI");

    while (try next_dir(efi, buf)) |dir| {
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

    pool_alloc_state = std.heap.ArenaAllocator.init(uefi_pool_alloc.allocator);
    pool_alloc = pool_alloc_state.allocator();

    var alloc = pool_alloc;

    var handles = blk: {
        var handle_ptr: [*]uefi.Handle = undefined;
        var res_size: usize = undefined;

        try boot_services.locateHandleBuffer(
            .ByProtocol,
            &SimpleFileSystemProtocol.guid,
            null,
            &res_size,
            &handle_ptr,
        ).err();

        break :blk handle_ptr[0..res_size];
    };
    defer uefi.raw_pool_allocator.free(handles);

    var loaders = std.ArrayList(Loader).init(alloc);

    // var map_maybe = linux.find_roots(alloc) catch |e| blk: {
    //     try out.printf("caught in root: {s}\r\n", .{@errorName(e)});
    //     _ = boot_services.stall(1000 * 1000);
    //     break :blk null;
    // };

    // if (map_maybe) |map| {
    //     var it = map.iterator();

    //     while (it.next()) |entry| {
    //         try out.printf("{}: ", .{entry.key_ptr.*});
    //         try out.print16ln(entry.value_ptr.*.ptr);

    //         _ = boot_services.stall(1000 * 1000);
    //     }
    // }

    // const LoaderMenu = Menu(Loader, MenuError);
    const LoaderMenu = Menu(MenuError);
    const MenuEntry = LoaderMenu.MenuEntry;

    var entries = std.ArrayList(MenuEntry).init(alloc);

    var buf: [1024]u8 align(8) = undefined;

    for (handles) |handle| {
        var sfsp = try boot_services.openProtocolSt(SimpleFileSystemProtocol, handle);
        var device = try boot_services.openProtocolSt(DevicePathProtocol, handle);

        var fp: *const FileProtocol = undefined;

        try sfsp.openVolume(&fp).err();

        var size = buf.len;

        try fp.getInfo(&FileSystemInfo.guid, &size, &buf).err();

        var info = @ptrCast(*FileSystemInfo, &buf);
        // Have to dupe the label as its from the buffer, which we'll overwrite.
        var label = try alloc.dupeZ(u16, std.mem.span(info.getVolumeLabel()));

        var disk_info = DiskInfo{
            .disk = device,
            .disk_name = label,
        };

        // Scanning the root directory
        while (try scan_dir(fp, &buf)) |fname| {
            var name = try alloc.dupeZ(u16, fname);

            try out.print16(name.ptr);
            try out.print("\r\n");

            try loaders.append(Loader{
                .disk_info = disk_info,
                .file_name = name,
            });
        }

        try linux.find_kernels(alloc, &loaders, &entries, fp, disk_info, &buf);

        try scan_efi(alloc, &loaders, fp, disk_info, &buf);

        for (exceptions) |exception| {
            var efp: *const FileProtocol = undefined;

            fp.open(&efp, exception, FileProtocol.efi_file_mode_read, 0).err() catch {
                continue;
            };

            try loaders.append(Loader{
                .disk_info = disk_info,
                .file_name = exception,
            });
        }
    }

    try out.println("creating entires");

    for (loaders.items) |*entry| {
        var desc = try std.mem.concat(alloc, u16, &[_][]const u16{
            entry.disk_info.disk_name,
            utf16_str(": "),
            entry.file_name,
            &[_]u16{0},
        });

        try entries.append(MenuEntry{
            .description = desc[0 .. desc.len - 1 :0],
            .callback = .{ .WithData = .{
                .fun = Loader.wrapped_load,
                .data = entry,
            } },
        });
    }

    try entries.append(MenuEntry{
        .description = utf16_str("Reboot into firmware"),
        .callback = .{ .Empty = reboot_into_firmware },
    });

    try entries.append(MenuEntry{
        .description = utf16_str("Exit"),
        .callback = .{ .Empty = die_fast },
    });

    // try out.reset(false);

    var menu = LoaderMenu.init(entries.items, out, con_in);

    while (true) {
        var entry = try menu.next();

        var err = switch (entry.callback) {
            .WithData => |info| blk: {
                break :blk info.fun(info.data);
            },
            .Empty => |fun| blk: {
                break :blk fun();
            },
        };

        err catch |e| {
            try out.reset(false);

            try out.printf("error in menu callback: {s}\r\n", .{@errorName(e)});
            _ = boot_services.stall(1000 * 1000);

            try out.reset(false);
            continue;
        };

        unreachable;
    }
}

const f_panic = @import("panic.zig");
pub fn panic(message: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
    f_panic.panic(message, trace);
}

pub fn die_fast() noreturn {
    f_panic.die(.Success);
}
