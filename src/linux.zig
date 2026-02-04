const std = @import("std");
const builtin = @import("builtin");

const device_path = @import("device_path.zig");
const main = @import("main.zig");
const menus = @import("menu.zig");
const gpt = @import("gpt.zig");
const Output = @import("Output.zig");

const uefi = std.os.uefi;

const Status = uefi.Status;

const protocols = uefi.protocol;
const FileProtocol = protocols.File;
const DevicePathProtocol = protocols.DevicePath;

const Allocator = std.mem.Allocator;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

const Loader = main.Loader;
const DiskInfo = main.DiskInfo;
const LoaderMenu = main.LoaderMenu;

const Menu = menus.Menu;
const GuidNameMap = gpt.GuidNameMap;

extern var boot_services: *uefi.tables.BootServices;

var out = &main.out;

const Lba = u64;

const kernel_patterns = [_][:0]const u16{
    utf16_str("vmlinuz-"),
    utf16_str("vmlinuz"),
};

const initrd_patterns = [_][:0]const u16{
    utf16_str("initramfs-"),
    utf16_str("initrd-"),
    utf16_str("init-"),
    utf16_str("init"),
};

const KernelLoader = struct {
    loader: Loader,
    root: []const u16,
    initrd: []const u16,
    alloc: Allocator,

    pub fn load(self_opaque: *const anyopaque) Loader.LoaderError!void {
        const self = @as(
            *const KernelLoader,
            @ptrCast(@alignCast(self_opaque)),
        );

        // maybe pool?
        var args = try std.mem.concat(self.alloc, u16, &[_][]const u16{
            utf16_str("ro root=PARTUUID="),
            self.root,
            utf16_str(" initrd="),
            self.initrd,
            &[_]u16{0},
        });

        var ld = self.loader;

        ld.args = args[0 .. args.len - 1 :0];

        try ld.load();
    }
};

const EfiFileReader = struct {
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;
    const Limit = std.Io.Limit;

    const vtable = Reader.VTable {
        .stream = stream,
    };

    iface: std.Io.Reader,
    file: *protocols.File,
    err: ?(protocols.File.SeekError || protocols.File.ReadError) = null,

    fn stream(r: *Reader, w: *Writer, l: Limit) Reader.StreamError!usize {
        const self: *EfiFileReader = @fieldParentPtr("iface", r);
        const f = self.file;

        const buf = try w.writableSliceGreedy(1);

        const amount = f.read(l.slice(buf)) catch |e| {
            self.err = e;
            return error.ReadFailed;
        };

        w.advance(amount);

        return amount;
    }

    fn init(file: *protocols.File, buf: []u8) @This() {
        return .{
            .file = file,
            .iface = .{
                .vtable = &vtable,
                .buffer = buf,
                .seek = 0,
                .end = 0
            },
        };
    }
};

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

    const conf_sentinel = conf_name[0 .. conf_name.len - 1 :0];
    try out.print16ln(conf_sentinel.ptr);

    const efp = fp.open(conf_sentinel, .read, .{}) catch |e| {
        try out.printf("{s}\r\n", .{@errorName(e)});
        return e;
    };

    var buf: [4096]u8 = undefined;
    var reader = EfiFileReader.init(efp, &buf);

    var utf8 = try reader.iface.readAlloc(alloc, 1024 * 1024);
    defer alloc.free(utf8);

    if (std.mem.endsWith(u8, utf8, "\r\n")) {
        utf8 = utf8[0 .. utf8.len - 2];
    }

    if (std.mem.endsWith(u8, utf8, "\n")) {
        utf8 = utf8[0 .. utf8.len - 1];
    }

    return try std.unicode.utf8ToUtf16LeAllocZ(alloc, utf8);
}

pub fn find_initrd(
    alloc: Allocator,
    fp: *const FileProtocol,
    name: []const u16,
) ![]const u16 {
    // var buf: [128]u8 = undefined;

    for (initrd_patterns) |pat| {
        var initrd_name = try std.mem.concat(
            alloc,
            u16,
            &[_][]const u16{
                pat,
                name,
                utf16_str(".img"),
                &[_]u16{0},
            },
        );
        errdefer alloc.free(initrd_name);

        const initrd = initrd_name[0 .. initrd_name.len - 1 :0];

        // Check that initrd-(...) exists
        _ = fp.open(initrd, .read, .{}) catch {
            alloc.free(initrd_name);
            continue;
        };

        // Return it without the null terminator for concat purposes
        return initrd_name[0 .. initrd_name.len - 1];
    }

    return error.NotFound;
}
pub fn load_args(
    alloc: Allocator,
    fp: *const FileProtocol,
    kernel: [:0]const u16,
    init: []const u16,
) ![]u16 {
    const conf = try read_conf(alloc, fp, kernel[0..]);
    const args = try std.mem.concat(alloc, u16, &[_][]const u16{
        conf,
        utf16_str(" initrd="),
        init,
        &[_]u16{0},
    });

    return args;
}

/// Finds any kernels of the "typical" naming scheme and adds them to the loader
/// list, along with an associated menu entry Additionally checks /boot, in the
/// case that the partition is a root partition for an OS.
pub fn find_kernels(
    alloc: Allocator,
    roots: *GuidNameMap,
    li: *std.ArrayList(Loader),
    entries: *std.ArrayList(LoaderMenu.MenuEntry),
    fp: *FileProtocol,
    disk_info: DiskInfo,
    buf: []align(8) u8,
) !void {
    try _find_kernels(alloc, roots, li, entries, fp, disk_info, null, buf);

    // Check /boot if it exists for stuff like an ext4 partition
    const boot_fp = fp.open(utf16_str("boot"), .read, .{}) catch {
        return;
    };

    try _find_kernels(alloc, roots, li, entries, boot_fp, disk_info, utf16_str("boot"), buf);
}

fn _find_kernels(
    alloc: Allocator,
    roots: *GuidNameMap,
    li: *std.ArrayList(Loader),
    entries: *std.ArrayList(LoaderMenu.MenuEntry),
    fp: *FileProtocol,
    disk_info: DiskInfo,
    root: ?[:0]const u16,
    buf: []align(8) u8,
) !void {
    // Reset the position as we've already scanned
    // past everything while detecting .efi loaders
    try fp.setPosition(0);

    while (try fp.read(buf) != 0) {
        var file_info = @as(*FileProtocol.Info.File, @ptrCast(buf.ptr));

        if (file_info.attribute.directory)
            continue;

        var fname = std.mem.span(file_info.getFileName());

        for (kernel_patterns) |pat| {
            if (!std.mem.startsWith(u16, fname, pat)) {
                continue;
            }

            if (std.mem.endsWith(u16, fname, utf16_str(".conf"))) {
                continue;
            }

            // Go to the end because we have a sentinel-terminated ptr already
            const name = fname[pat.len.. :0];

            const init = blk: {
                const init = find_initrd(alloc, fp, name) catch {
                    continue;
                };

                if (root) |r| {
                    var res = try std.mem.concat(alloc, u16, &[_][]const u16{
                        r,
                        utf16_str("\\"),
                        init,
                        &[_]u16{0},
                    });

                    alloc.free(init);

                    break :blk res[0 .. res.len - 1 :0];
                }

                break :blk init;
            };

            const loaded_args = load_args(alloc, fp, fname, init) catch null;

            const file_path = if (root) |r|
                try main.join_paths(alloc, r, fname)
            else
                try alloc.dupeZ(u16, fname);

            // If we have args, use them
            if (loaded_args) |args| {
                try li.append(alloc, Loader{
                    .disk_info = disk_info,
                    .file_name = file_path,
                    .args = args[0 .. args.len - 1 :0],
                });

                alloc.free(init);

                continue;
            }

            // Otherwise, create a menu to choose from possible root disks
            const KernelMenu = Menu(main.MenuError);
            const MenuEntry = KernelMenu.MenuEntry;

            var disk_entries = try std.ArrayList(MenuEntry).initCapacity(alloc, 3);
            const internal_loader = Loader{
                .disk_info = disk_info,
                .file_name = file_path,
                .args = null,
            };

            var it = roots.iterator();
            while (it.next()) |v| {
                var guid16: [128:0]u16 = undefined;
                var guid_buf: [128]u8 = undefined;

                const guid8 = try std.fmt.bufPrint(&guid_buf, "{f}", .{v.key_ptr.*});
                const ind = try std.unicode.utf8ToUtf16Le(&guid16, guid8);

                var desc = try std.mem.concat(alloc, u16, &[_][]const u16{
                    v.value_ptr.*,
                    utf16_str(": "),
                    guid16[0..ind],
                    &[_]u16{0},
                });

                const guid16_alloc = try alloc.dupeZ(u16, guid16[0..ind]);

                const loader = try alloc.create(KernelLoader);
                loader.* = KernelLoader{
                    .loader = internal_loader,
                    .root = guid16_alloc,
                    .initrd = init,
                    .alloc = alloc,
                };

                try disk_entries.append(alloc, MenuEntry{
                    .description = desc[0 .. desc.len - 1 :0],
                    .callback = .{ .WithData = .{
                        .fun = KernelLoader.load,
                        .data = loader,
                    } },
                });
            }

            try disk_entries.append(alloc, MenuEntry{ .description = utf16_str("Back"), .callback = .{ .Back = {} } });

            const menu = try alloc.create(KernelMenu);
            menu.* = KernelMenu.init(
                try disk_entries.toOwnedSlice(alloc),
                Output{ .con = uefi.system_table.con_out.? },
                uefi.system_table.con_in.?,
            );

            const MenuRunner = struct {
                pub fn run_menu(opaque_ptr: *anyopaque) main.MenuError!void {
                    var menu_ptr = @as(*KernelMenu, @ptrCast(@alignCast(opaque_ptr)));

                    try menu_ptr.run();
                }
            };

            var desc = try std.mem.concat(alloc, u16, &[_][]const u16{
                disk_info.label,
                utf16_str(": "),
                file_path,
                &[_]u16{0},
            });

            try entries.append(alloc, MenuEntry{
                .description = desc[0 .. desc.len - 1 :0],
                .callback = .{
                    .WithData = .{
                        .fun = MenuRunner.run_menu,
                        .data = menu,
                    },
                },
            });
        }
    }
}
