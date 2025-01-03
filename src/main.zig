const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;

const protocols = uefi.protocol;

const menus = @import("menu.zig");
const device_path = @import("device_path.zig");
const fs_info = @import("fs_info.zig");
const linux = @import("linux.zig");
const gpt = @import("gpt.zig");

const Output = @import("Output.zig");

const Allocator = std.mem.Allocator;
const Status = uefi.Status;

const Menu = menus.Menu;
const GuidNameMap = gpt.GuidNameMap;

const FileInfo = uefi.FileInfo;
const FileProtocol = protocols.File;
const LoadedImageProtocol = protocols.LoadedImage;
const SimpleFileSystemProtocol = protocols.SimpleFileSystem;
const DevicePathProtocol = protocols.DevicePath;
const FileSystemInfo = fs_info.FileSystemInfo;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

pub const LoaderMenu = Menu(MenuError);
const MenuEntry = LoaderMenu.MenuEntry;

pub export var boot_services: *uefi.tables.BootServices = undefined;

pub var out: Output = undefined;

var sys_table: *uefi.tables.SystemTable = undefined;
var con_in: *protocols.SimpleTextInput = undefined;
var con_out: *protocols.SimpleTextOutput = undefined;

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

    rs.getVariable(utf16_str("OsIndications"), global_var, null, &size, &os_ind).err() catch {
        os_ind = 0;
    };

    if ((os_ind & boot_to_firmware) == 0) {
        const attrs: u32 = runtime_access | bootservice_access | nonvolatile_access;

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
        var self = @as(*align(@alignOf(Self)) Self, @ptrCast(@alignCast(opaque_ptr)));

        try self.load();
    }

    pub fn load(self: *const Self) LoaderError!void {
        var img: ?uefi.Handle = undefined;

        const image_path = try device_path.file_path(pool_alloc, self.disk_info.disk, self.file_name);
        try boot_services.loadImage(false, uefi.handle, image_path, null, 0, &img).err();

        var img_proto = try boot_services.openProtocolSt(LoadedImageProtocol, img.?);

        if (self.args) |options| {
            out.print("loading ") catch {};
            out.print16(self.file_name) catch {};
            out.print(", options: ") catch {};
            out.print16ln(options) catch {};

            _ = boot_services.stall(2 * 1000 * 1000);

            img_proto.load_options = options.ptr;
            img_proto.load_options_size = @intCast((options.len + 1) * @sizeOf(u16));
        } else {
            img_proto.load_options = null;
            img_proto.load_options_size = 0;
        }

        try boot_services.startImage(img.?, null, null).err();
    }
};

pub const DiskInfo = struct {
    disk: *DevicePathProtocol,
    label: [:0]const u16,
};

pub fn join_paths(alloc: Allocator, prefix: [:0]const u16, suffix: [:0]const u16) ![:0]const u16 {
    var res: []u16 = try alloc.alloc(u16, prefix.len + 1 + suffix.len + 1);
    res[res.len - 1] = 0;

    @memcpy(res[0..prefix.len], prefix);
    @memcpy(res[prefix.len .. prefix.len + 1], utf16_str("\\"));
    @memcpy(res[prefix.len + 1 .. res.len - 1], suffix);

    return res[0 .. res.len - 1 :0];
}

/// Returns the next file ending in .efi or .EFI in the directory, if any exist.
pub fn scan_dir(fp: *const FileProtocol, buf: []align(8) u8) !?[:0]const u16 {
    var size = buf.len;

    while (true) {
        size = buf.len;

        try fp.read(&size, buf.ptr).err();

        if (size == 0)
            break;

        var file_info = @as(*FileInfo, @ptrCast(buf.ptr));

        if ((file_info.attribute & FileInfo.efi_file_directory) != 0)
            continue;

        const fname = std.mem.span(file_info.getFileName());

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

        var file_info = @as(*FileInfo, @ptrCast(buf.ptr));

        const fname = std.mem.span(file_info.getFileName());

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

/// Add all found EFI bootloader entries in /EFI for the given file protocol to `li`
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
        const base_path = try join_paths(alloc, efi_str, dir.dir_name);
        defer alloc.free(base_path);

        while (try scan_dir(dir.handle, buf)) |fname| {
            const name = try join_paths(alloc, base_path, fname);

            try out.print16(name.ptr);
            try out.print("\r\n");

            try li.append(Loader{
                .disk_info = disk_info,
                .file_name = name,
            });
        }
    }
}

/// Given a handle with a SimpleFileSystemProtocol, add all EFI entries of form `EFI/[folder]/*.efi`,
/// linux kernels with the "typical" names, and EFI files in the root directory. Additionaly, add
/// anything in the 'exceptions' case - such as Windows' boot loader and macOS'.
pub fn process_handle(
    alloc: Allocator,
    buf: []align(8) u8,
    handle: uefi.Handle,
    roots: *GuidNameMap,
    loaders: *std.ArrayList(Loader),
    entries: *std.ArrayList(MenuEntry),
) !void {
    var sfsp = try boot_services.openProtocolSt(SimpleFileSystemProtocol, handle);
    const device = try boot_services.openProtocolSt(DevicePathProtocol, handle);

    var fp: *const FileProtocol = undefined;

    try sfsp.openVolume(&fp).err();

    var size = buf.len;

    try fp.getInfo(&FileSystemInfo.guid, &size, buf.ptr).err();

    var info = @as(*FileSystemInfo, @ptrCast(buf));

    const guid = blk: {
        var iter: ?*DevicePathProtocol = device;

        while (iter) |dpp| : (iter = dpp.next()) {
            const path = dpp.getDevicePath() orelse continue;

            const mdp = switch (path) {
                .Media => |m| m,
                else => continue,
            };

            const disk = switch (mdp) {
                .HardDrive => |hd| hd,
                else => continue,
            };

            try out.printf("sig type: {s}\r\n, sig: {}\r\n", .{
                @tagName(disk.signature_type),
                @as(uefi.Guid, @bitCast(disk.partition_signature)),
            });

            break :blk @as(uefi.Guid, @bitCast(disk.partition_signature));
        }

        unreachable;
    };

    const label = blk: {
        var vol = std.mem.span(info.getVolumeLabel());

        if (vol.len == 0) {
            vol = utf16_str("unknown disk");
        }

        if (roots.get(guid)) |fs_label| {
            var label = try std.mem.concat(alloc, u16, &[_][]const u16{
                vol,
                utf16_str(" - "),
                fs_label,
                &[_]u16{0},
            });

            break :blk label[0 .. label.len - 1 :0];
        } else {
            break :blk try alloc.dupeZ(u16, vol);
        }
    };

    const disk_info = DiskInfo{
        .disk = device,
        .label = label,
    };

    // Scanning the root directory
    while (try scan_dir(fp, buf)) |fname| {
        const name = try alloc.dupeZ(u16, fname);

        try out.print16(name.ptr);
        try out.print("\r\n");

        try loaders.append(Loader{
            .disk_info = disk_info,
            .file_name = name,
        });
    }

    linux.find_kernels(alloc, roots, loaders, entries, fp, disk_info, buf) catch |e| {
        try out.printf("unable to find linux kernels - err: {s}\r\n", .{@errorName(e)});
    };

    scan_efi(alloc, loaders, fp, disk_info, buf) catch |e| {
        try out.printf("unable to scan efi - err: {s}\r\n", .{@errorName(e)});
    };

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

    try out.println("");
}

/// Loads all drivers in "[/boot/]EFI/zbl/drivers"
pub fn load_drivers(alloc: Allocator, device_handle: uefi.Handle) !void {
    const dp = try boot_services.openProtocolSt(DevicePathProtocol, device_handle);
    const fp = try boot_services.openProtocolSt(SimpleFileSystemProtocol, device_handle);

    var root: *const protocols.File = undefined;
    try fp.openVolume(&root).err();

    var drivers: *const protocols.File = undefined;
    // If the folder doesn't exist, we just exit.
    root.open(&drivers, utf16_str("EFI\\zbl\\drivers"), FileProtocol.efi_file_mode_read, 0).err() catch {
        return;
    };

    var buf: [1024]u8 align(8) = undefined;

    while (try scan_dir(drivers, &buf)) |fname| {
        const path = try join_paths(alloc, utf16_str("EFI\\zbl\\drivers"), fname);
        const file_dp = try device_path.file_path(alloc, dp, path);

        var img: ?uefi.Handle = undefined;
        try boot_services.loadImage(false, uefi.handle, file_dp, null, 0, &img).err();

        var img_proto = try boot_services.openProtocolSt(LoadedImageProtocol, img.?);
        img_proto.load_options = null;
        img_proto.load_options_size = 0;

        boot_services.startImage(img.?, null, null).err() catch |e| {
            switch (e) {
                // Used by EFI drivers to indicate that the loader should
                // continue after loading it.
                error.Aborted => continue,
                else => return e,
            }
        };
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

    pool_alloc_state = std.heap.ArenaAllocator.init(uefi.pool_allocator);
    pool_alloc = pool_alloc_state.allocator();

    const alloc = pool_alloc;

    const img = try boot_services.openProtocolSt(protocols.LoadedImage, uefi.handle);

    if (img.device_handle) |dh| {
        load_drivers(alloc, dh) catch |e| {
            try out.printf("Failed to load drivers! {s}\n!", .{@errorName(e)});
            try boot_services.stall(3 * 1000 * 1000).err();
        };
    }

    const handles = blk: {
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

    var entries = std.ArrayList(MenuEntry).init(alloc);

    var roots = try gpt.find_roots(alloc);

    var miter = roots.iterator();
    while (miter.next()) |kvp| {
        try out.printf("{}: {}\r\n", .{ kvp.key_ptr.*, std.unicode.fmtUtf16le(kvp.value_ptr.*) });
    }

    var buf: [1024]u8 align(8) = undefined;

    for (handles) |handle| {
        process_handle(alloc, &buf, handle, &roots, &loaders, &entries) catch |e| {
            try out.printf("Unable to process handle: {s}\r\n", .{@errorName(e)});
        };
    }

    for (loaders.items) |*entry| {
        var desc = try std.mem.concat(alloc, u16, &[_][]const u16{
            entry.disk_info.label,
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
        .callback = .{ .Back = {} },
    });

    try out.reset(false);

    var menu = LoaderMenu.init(entries.items, out, con_in);

    try menu.run();

    // If we've returned from the menu - then the user hit back, exit.
    f_panic.die(.Success);
}

const f_panic = @import("panic.zig");
pub fn panic(message: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    f_panic.panic(message, trace, ret_addr);
}
