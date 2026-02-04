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

const FileProtocol = protocols.File;
const FileInfo = FileProtocol.Info.File;
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
    UnexpectedStatus,
    DeviceError,
    NotReady
} || Loader.LoaderError || ResetError;

const ResetError = error{
    Unexpected,
    DeviceError,
    Unsupported,
    InvalidParameter,
    SecurityViolation,
    WriteProtected,
    OutOfResources,
    NotFound
};

pub fn reboot_into_firmware() ResetError!void {
    // const nonvolatile_access = 0x01;
    // const bootservice_access = 0x02;
    // const runtime_access = 0x04;

    const boot_to_firmware = 0x01;

    const VariableAttributes = uefi.tables.RuntimeServices.VariableAttributes;

    const rs = sys_table.runtime_services;
    const global_var = &uefi.tables.global_variable;

    var size: usize = @sizeOf(usize);
    var os_ind: usize = undefined;

    rs._getVariable(utf16_str("OsIndications"), global_var, null, &size, &os_ind).err() catch {
        os_ind = 0;
    };

    if ((os_ind & boot_to_firmware) == 0) {
        const attrs: VariableAttributes = .{ .runtime_access = true, .bootservice_access = true, .non_volatile = true };

        os_ind |= boot_to_firmware;

        try rs.setVariable(utf16_str("OsIndications"), global_var, attrs, @ptrCast(&os_ind));
    }

    uefi.system_table.runtime_services.resetSystem(.cold, .success, null);
}

pub const Loader = struct {
    const Self = @This();

    file_name: [:0]const u16,
    disk_info: DiskInfo,
    args: ?[:0]u16 = null,

    pub const LoaderError = error{
        OutOfMemory,
        Unexpected,
        InvalidParameter,
        SecurityViolation,
        Unsupported,
    };

    pub fn wrapped_load(opaque_ptr: *anyopaque) LoaderError!void {
        var self = @as(*align(@alignOf(Self)) Self, @ptrCast(@alignCast(opaque_ptr)));

        try self.load();
    }

    pub fn load(self: *const Self) LoaderError!void {
        var img: uefi.Handle = undefined;

        const image_path = try device_path.file_path(pool_alloc, self.disk_info.disk, self.file_name);
        boot_services._loadImage(false, uefi.handle, image_path, null, 0, &img).err() catch |e| {
            switch (e) {
                error.BufferTooSmall => return error.OutOfMemory,
                error.Unsupported => return error.Unsupported,
                else => return error.Unexpected
            }
        };

        var img_proto = try boot_services.handleProtocol(LoadedImageProtocol, img)
        orelse std.debug.panic("image had no image protocol!", .{});

        if (self.args) |options| {
            out.print("loading ") catch {};
            out.print16(self.file_name) catch {};
            out.print(", options: ") catch {};
            out.print16ln(options) catch {};

            boot_services.stall(2 * 1000 * 1000) catch {};

            img_proto.load_options = options.ptr;
            img_proto.load_options_size = @intCast((options.len + 1) * @sizeOf(u16));
        } else {
            img_proto.load_options = null;
            img_proto.load_options_size = 0;
        }

        // TODO: print output?
        _ = try boot_services.startImage(img);
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
pub fn scan_dir(fp: *FileProtocol, buf: []align(8) u8) !?[:0]const u16 {
    while (true) {
        const size = try fp.read(buf);

        if (size == 0)
            break;

        var file_info = @as(*FileProtocol.Info.File, @ptrCast(buf.ptr));

        if (file_info.attribute.directory)
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
    handle: *FileProtocol,

    // I don't love this taking it by value
    // but by ptr is annoying because
    // zig loops return const values(??)
    pub fn deinit(self: *Directory) void {
        self.handle.close() catch {};
    }
};

pub fn next_dir(fp: *FileProtocol, buf: []align(8) u8) !?Directory {
    while (try fp.read(buf) != 0) {
        var file_info = @as(*FileProtocol.Info.File, @ptrCast(buf.ptr));

        const fname = std.mem.span(file_info.getFileName());

        if (std.mem.eql(u16, fname, utf16_str("..")) or std.mem.eql(u16, fname, utf16_str(".")))
            continue;

        if (file_info.attribute.directory) {
            const handle = try fp.open(file_info.getFileName(), .read, .{});

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
    const efi = fp.open(utf16_str("EFI"), .read, .{}) catch {
        return;
    };

    const efi_str = utf16_str("EFI");

    while (try next_dir(efi, buf)) |dir_| {
        // un-const it, since doing it in the loop
        // materializes a temporary and that becomes const
        // because idk, zig.
        var dir = dir_;
        defer dir.deinit();

        // Copy out the path with the prefix, as it's in the buffer which will be cleared.
        const base_path = try join_paths(alloc, efi_str, dir.dir_name);
        defer alloc.free(base_path);

        while (try scan_dir(dir.handle, buf)) |fname| {
            const name = try join_paths(alloc, base_path, fname);

            try out.print16(name.ptr);
            try out.print("\r\n");

            try li.append(alloc, Loader{
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
    var sfsp = try boot_services.handleProtocol(SimpleFileSystemProtocol, handle) orelse return;
    const device = try boot_services.handleProtocol(DevicePathProtocol, handle) orelse return;

    var fp = try sfsp.openVolume();

    var info = try fp.getInfo(.file_system, buf);

    // var info = @as(*FileSystemInfo, @ptrCast(buf));

    const guid = blk: {
        var iter: ?*const DevicePathProtocol = device;

        while (iter) |dpp| : (iter = dpp.next()) {
            const path = dpp.getDevicePath() orelse continue;

            const mdp = switch (path) {
                .media => |m| m,
                else => continue,
            };

            const disk = switch (mdp) {
                .hard_drive => |hd| hd,
                else => continue,
            };

            try out.printf("sig type: {s}\r\n, sig: {f}\r\n", .{
                @tagName(disk.signature_type),
                @as(uefi.Guid, @bitCast(disk.partition_signature)),
            });

            break :blk @as(uefi.Guid, @bitCast(disk.partition_signature));
        }

        @panic("No GUID!");
    };

    const label = blk: {
        var vol = std.mem.span(info.getVolumeLabel());

        if (vol.len == 0) {
            // TODO: refactor
            var guid16: [128:0]u16 = undefined;
            var guid_buf: [128]u8 = undefined;

            const guid8 = try std.fmt.bufPrint(&guid_buf, "{f}", .{guid});
            const ind = try std.unicode.utf8ToUtf16Le(&guid16, guid8);
            guid16[ind] = 0;

            vol = try alloc.dupeZ(u16, guid16[0 .. ind : 0]); // utf16_str("unknown disk");
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

        try loaders.append(alloc, Loader{
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
        _ = fp.open(exception, .read, .{}) catch {
            continue;
        };

        try loaders.append(alloc, Loader{
            .disk_info = disk_info,
            .file_name = exception,
        });
    }

    try out.println("");
}

/// Loads all drivers in "[/boot/]EFI/zbl/drivers"
pub fn load_drivers(alloc: Allocator, device_handle: uefi.Handle) !void {
    const dp = try boot_services.handleProtocol(DevicePathProtocol, device_handle) orelse std.debug.panic("device has no device path", .{});
    const fp = try boot_services.handleProtocol(SimpleFileSystemProtocol, device_handle) orelse return;

    const root = try fp.openVolume();

    // If the folder doesn't exist, we just exit.
    const drivers = root.open(utf16_str("EFI\\zbl\\drivers"), .read, .{}) catch {
        return;
    };

    var buf: [1024]u8 align(8) = undefined;

    while (try scan_dir(drivers, &buf)) |fname| {
        const path = try join_paths(alloc, utf16_str("EFI\\zbl\\drivers"), fname);
        const file_dp = try device_path.file_path(alloc, dp, path);

        var img: uefi.Handle = undefined;
        try boot_services._loadImage(false, uefi.handle, file_dp, null, 0, &img).err();

        // It's literally an image.
        var img_proto = try boot_services.handleProtocol(LoadedImageProtocol, img) orelse unreachable;
        img_proto.load_options = null;
        img_proto.load_options_size = 0;

        const status = try boot_services.startImage(img);

        if (status.code == .aborted) {
            continue;
        } else {
            return uefi.unexpectedStatus(status.code);
        }
    }
}

pub fn main() void {
    caught_main() catch |e| {
        // If this doesn't work then oh well.
        out.printf("Caught error: {s}\n!", .{@errorName(e)}) catch {};
        boot_services.stall(3 * 1000 * 1000) catch {};
    };
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

    const img = try boot_services.handleProtocol(protocols.LoadedImage, uefi.handle);

    if (img.?.device_handle) |dh| {
        load_drivers(alloc, dh) catch |e| {
            try out.printf("Failed to load drivers! {s}\n!", .{@errorName(e)});
            try boot_services.stall(3 * 1000 * 1000);
        };
    }

    const handles = blk: {
        var handle_ptr: [*]uefi.Handle = undefined;
        var res_size: usize = undefined;

        try boot_services._locateHandleBuffer(
            .by_protocol,
            &SimpleFileSystemProtocol.guid,
            null,
            &res_size,
            &handle_ptr,
        ).err();

        break :blk handle_ptr[0..res_size];
    };
    defer uefi.raw_pool_allocator.free(handles);

    var loaders = std.ArrayList(Loader).empty;

    var entries = std.ArrayList(MenuEntry).empty;

    var roots = try gpt.find_roots(alloc);

    // var miter = roots.iterator();
    // while (miter.next()) |kvp| {
        // try out.printf("{}: {}\r\n", .{ kvp.key_ptr.*, std.unicode.fmtUtf16le(kvp.value_ptr.*) });
    // }

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

        try entries.append(alloc, MenuEntry{
            .description = desc[0 .. desc.len - 1 :0],
            .callback = .{ .WithData = .{
                .fun = Loader.wrapped_load,
                .data = entry,
            } },
        });
    }

    try entries.append(alloc, MenuEntry{
        .description = utf16_str("Reboot into firmware"),
        .callback = .{ .Empty = reboot_into_firmware },
    });

    try entries.append(alloc, MenuEntry{
        .description = utf16_str("Exit"),
        .callback = .{ .Back = {} },
    });

    try entries.append(alloc, MenuEntry {
        .description = utf16_str("Print roots"),
        .callback = .{ .WithData = .{
            .fun = print_roots,
            .data = &roots
        } },
    });

    try out.reset(false);

    var menu = LoaderMenu.init(entries.items, out, con_in);

    try menu.run();

    // If we've returned from the menu - then the user hit back, exit.
    f_panic.die(.success);
}

pub fn print_roots(opaque_ptr: *anyopaque) !void {
    var roots: *GuidNameMap = @alignCast(@ptrCast(opaque_ptr));

    try out.reset(false);

    var it = roots.iterator();
    while (it.next()) |v| {
        var guid16: [128:0]u16 = undefined;
        var guid_buf: [128]u8 = undefined;

        const guid8 = try std.fmt.bufPrint(&guid_buf, "{f}", .{v.key_ptr.*});
        const ind = try std.unicode.utf8ToUtf16Le(&guid16, guid8);

        const desc = try std.mem.concat(pool_alloc, u16, &[_][]const u16{
            v.value_ptr.*,
            utf16_str(": "),
            guid16[0..ind],
            &[_]u16{0},
        });

        out.print16ln(desc[0 .. desc.len - 1:0].ptr) catch |e| {
            guid16[ind] = 0;

            try out.print16(guid16[0 .. ind : 0]);
            try out.print(": ");
            try out.printf("invalid desc {s}\r\n", .{@errorName(e)});

            try out.println("==========");

            const partitions = @divFloor(desc.len, 20);

            for (0..partitions) |i| {
                try out.printf("{any}\r\n", .{desc[i * 20 .. @min((i + 1) * 20, desc.len)]});
            }

            if ((partitions * 20) != desc.len) {
                try out.printf("{any}\r\n", .{desc[partitions * 20 .. desc.len]});
            }

            try out.println("==========");
        };
    }

    const input_events = [_]uefi.Event{uefi.system_table.con_in.?.wait_for_key};

    // Make sure we have at least a second to see the error
    // to prevent accidental dismissal of the message.
    uefi.system_table.boot_services.?.stall(1 * 1000 * 1000) catch {};

    // Wait for an input.
    _ = try uefi.system_table.boot_services.?.waitForEvent(&input_events);
}

const f_panic = @import("panic.zig");
pub fn panic(message: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    f_panic.panic(message, trace, ret_addr);
}
