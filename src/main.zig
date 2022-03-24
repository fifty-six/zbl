const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;

const protocols = uefi.protocols;

const menus = @import("menu.zig");
const device_path = @import("device_path.zig");
const uefi_pool_alloc = @import("uefi_pool_allocator.zig");
const fs_info = @import("fs_info.zig");

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
const utf16_strZ = std.unicode.utf8ToUtf16LeStringLiteral;

var sys_table: *uefi.tables.SystemTable = undefined;
var boot_services: *uefi.tables.BootServices = undefined;
var con_in: *protocols.SimpleTextInputProtocol = undefined;
var con_out: *protocols.SimpleTextOutputProtocol = undefined;
var out: Output = undefined;

var pool_alloc_state: std.heap.ArenaAllocator = undefined;
var pool_alloc: Allocator = undefined;

const exceptions = [_][:0]const u16{
    // Windows bootloader
    utf16_strZ("EFI\\Microsoft\\Boot\\bootmgfw.efi"),
    // Mac bootloader
    utf16_strZ("System\\Library\\CoreServices\\boot.efi"),
};

const kernel_patterns = [_][:0]const u16{
    utf16_str("vmlinuz-"),
};

// { 03 79 BE 4E - D7 06 - 43 7d - B0 37 -ED B8 2F B7 72 A4}
const block_io_protocol_guid align(8) = uefi.Guid{
    .time_low = 0x0379be4e,
    .time_mid = 0xd706,
    .time_high_and_version = 0x437d,
    .clock_seq_high_and_reserved = 0xb0,
    .clock_seq_low = 0x37,
    .node = [_]u8{ 0xed, 0xb8, 0x2f, 0xb7, 0x72, 0xa4 },
};

const root_partition_guid = switch (builtin.cpu.arch) {
    // 4f 68 bc e3 -e8 cd-4d b1-96 e7-fb ca f9 84 b7 09
    .x86_64 => uefi.Guid{
        .time_low = 0x4f68bce3,
        .time_mid = 0xe8cd,
        .time_high_and_version = 0x4db1,
        .clock_seq_high_and_reserved = 0x96,
        .clock_seq_low = 0xe7,
        .node = [_]u8{ 0xfb, 0xca, 0xf9, 0x84, 0xb7, 0x09 },
    },
    else => @compileError("unsupported architecture"),
};

pub const MenuError = error{
    GetVariableFailure,
    SetVariableFailure,
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

pub fn read_conf(
    alloc: Allocator,
    fp: *const FileProtocol,
    kernel: []const u16,
) ![]const u16 {
    var conf_name = try std.mem.concat(
        alloc,
        u16,
        &[_][]const u16{
            kernel,
            utf16_str(".conf"),
            &[_]u16{0},
        },
    );
    defer alloc.free(conf_name);

    var conf_sentinel = conf_name[0 .. conf_name.len - 1 :0];

    var efp: *FileProtocol = undefined;

    try fp.open(&efp, conf_sentinel, FileProtocol.efi_file_mode_read, 0).err();

    var utf8 = try efp.reader().readAllAlloc(alloc, 1024 * 1024);

    if (std.mem.endsWith(u8, utf8, "\r\n")) {
        utf8 = utf8[0 .. utf8.len - 2];
    }

    if (std.mem.endsWith(u8, utf8, "\n")) {
        utf8 = utf8[0 .. utf8.len - 1];
    }

    return try std.unicode.utf8ToUtf16LeWithNull(alloc, utf8);
}

pub fn find_initrd(
    alloc: Allocator,
    fp: *const FileProtocol,
    name: []const u16,
) ![]const u16 {
    var initrd_name = try std.mem.concat(
        alloc,
        u16,
        &[_][]const u16{
            utf16_str("initramfs-"),
            name,
            utf16_str(".img"),
            &[_]u16{0},
        },
    );
    errdefer alloc.free(initrd_name);

    var initrd = initrd_name[0 .. initrd_name.len - 1 :0];

    var efp: *const FileProtocol = undefined;

    // Check that initrd-(...) exists
    try fp.open(&efp, initrd, FileProtocol.efi_file_mode_read, 0).err();

    // Return it without the null terminator for concat purposes
    return initrd_name[0 .. initrd_name.len - 1];
}

pub fn find_linux_root(
    alloc: Allocator,
    handles: []uefi.Handle,
    buf: []align(8) u8,
) !void {
    _ = alloc;
    _ = buf;

    var root_guid: [16]u8 = undefined;

    std.mem.copy(u8, &root_guid, std.mem.asBytes(&root_partition_guid));

    try out.printf("required guid:           {any}\r\n", .{root_guid});

    for (handles) |handle| {
        var root_device = boot_services.openProtocolSt(DevicePathProtocol, handle) catch {
            try out.println("how tf");
            continue;
        };

        var device: ?*DevicePathProtocol = root_device;

        var str = try device_path.to_str(alloc, root_device);
        try out.print16ln(str);
        alloc.free(str);

        while (device) |d| : (device = d.next()) {
            var path = d.getDevicePath() orelse continue;

            var media = switch (path) {
                .Media => |m| m,
                else => continue,
            };

            var hdd = switch (media) {
                .HardDrive => |h| h,
                else => continue,
            };

            try out.printf("{} \r\n", .{hdd.signature_type});
            try out.printf("hdd partition signature: {any}\r\n", .{hdd.partition_signature});

            if (std.mem.eql(
                u8,
                @ptrCast(*const [16]u8, &root_partition_guid),
                &hdd.partition_signature,
            )) {
                try out.println("among us");
            }
        }
    }
}

pub fn add_kernel(
    alloc: Allocator,
    fp: *const FileProtocol,
    kernel: [:0]u16,
    name: []u16,
) ![]u16 {
    var init = try find_initrd(alloc, fp, name);
    defer alloc.free(init);

    var conf = try read_conf(alloc, fp, kernel[0..kernel.len]);
    var args = try std.mem.concat(alloc, u16, &[_][]const u16{
        conf,
        utf16_str(" initrd="),
        init,
        &[_]u16{0},
    });

    return args;
}

pub fn find_linux_kernels(
    alloc: Allocator,
    li: *std.ArrayList(Loader),
    fp: *const FileProtocol,
    disk_info: DiskInfo,
    buf: []align(8) u8,
) !void {
    var size = buf.len;

    // Reset the position as we've already scanned
    // past everything while detecting .efi loaders
    try fp.setPosition(0).err();

    while (true) {
        size = buf.len;

        try fp.read(&size, buf.ptr).err();

        if (size == 0)
            break;

        var file_info = @ptrCast(*FileInfo, buf.ptr);

        if ((file_info.attribute & FileInfo.efi_file_directory) != 0)
            continue;

        var fname = std.mem.span(file_info.getFileName());

        for (kernel_patterns) |pat| {
            if (!std.mem.startsWith(u16, fname, pat)) {
                continue;
            }

            // Gotta copy out of the buffer.
            var kernel = try alloc.dupeZ(u16, fname);

            // Go to the end because we have a sentinel-terminated ptr already
            var name = kernel[pat.len.. :0];

            var args = add_kernel(alloc, fp, kernel, name) catch continue;

            try li.append(Loader{
                .disk_info = disk_info,
                .file_name = kernel,
                .args = args[0 .. args.len - 1 :0],
            });
        }
    }
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

    var buf: [1024]u8 align(8) = undefined;

    // try find_linux_root(alloc, handles, &buf);

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

        try find_linux_kernels(alloc, &loaders, fp, disk_info, &buf);

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

    const LoaderMenu = Menu(Loader, MenuError);
    const MenuEntry = LoaderMenu.MenuEntry;
    var entries = std.ArrayList(MenuEntry).init(alloc);

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
                .fun = Loader.load,
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
        var entry = try menu.run();

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
