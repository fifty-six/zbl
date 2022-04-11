const std = @import("std");
const builtin = @import("builtin");

const device_path = @import("device_path.zig");
const main = @import("main.zig");
const menus = @import("menu.zig");
const Output = @import("Output.zig");

const uefi = std.os.uefi;

const Status = uefi.Status;

const protocols = uefi.protocols;
const FileProtocol = protocols.FileProtocol;
const DevicePathProtocol = protocols.DevicePathProtocol;
const FileInfo = protocols.FileInfo;

const Allocator = std.mem.Allocator;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

const Loader = main.Loader;
const DiskInfo = main.DiskInfo;
const Menu = menus.Menu;

extern var boot_services: *uefi.tables.BootServices;

var out = &main.out;

const kernel_patterns = [_][:0]const u16{
    utf16_str("vmlinuz-"),
};

const Lba = u64;

const GuidNameMap = std.AutoHashMap(uefi.Guid, [:0]const u16);

const MbrPartitionRecord = packed struct {
    boot_indicator: u8,

    start_head: u8,
    start_sector: u8,
    start_track: u8,

    os_indicator: u8,

    end_head: u8,
    end_sector: u8,
    end_track: u8,

    starting_lba: [4]u8,
    size_in_lba: [4]u8,
};

const MasterBootRecord = packed struct {
    boot_code: [440]u8,
    unique_signature: [4]u8,
    unknown: [2]u8,
    partitions: [4]MbrPartitionRecord,
    signature: u16,
};

const GptHeader = packed struct {
    signature: u64,

    revision: u32,
    header_size: u32,
    header_crc32: u32,
    reserved: u32,

    my_lba: Lba,
    alternate_lba: Lba,
    first_usable_lba: Lba,
    last_usable_lba: Lba,

    disk_guid: uefi.Guid,

    partition_entry_lba: Lba,
    entry_count: u32,
    entry_size: u32,
    parts_crc32: u32,
};

const EfiPartitionEntry = packed struct {
    partition_type: uefi.Guid,
    partition_uuid: uefi.Guid,

    starting_lba: Lba,
    ending_lba: Lba,

    attributes: u64,
    partition_name: [36]u16,
};

const PartitionInfoProtocol = packed struct {
    const Self = @This();

    const PartitionType = enum(u32) {
        Other = 0x00,
        Mbr = 0x01,
        Gpt = 0x02,
    };

    const Info = union(enum) {
        Mbr: *MbrPartitionRecord,
        Gpt: *EfiPartitionEntry,
    };

    revision: u32,
    type: PartitionType,
    system: u8,
    reserved: [7]u8,
    info: extern union {
        Mbr: MbrPartitionRecord,
        Gpt: EfiPartitionEntry,
    },

    pub fn getInfo(self: *Self) !Info {
        if (self.type == .Other) {
            return error.InvalidType;
        }

        return switch (self.type) {
            .Mbr => Info{ .Mbr = @ptrCast(*MbrPartitionRecord, @ptrCast([*]u8, &self) + @offsetOf(Self, "info")) },
            .Gpt => Info{ .Gpt = @ptrCast(*EfiPartitionEntry, @ptrCast([*]u8, &self) + @offsetOf(Self, "info")) },
            else => unreachable,
        };
    }

    pub const guid align(8) = uefi.Guid{
        .time_low = 0x8cf2f62c,
        .time_mid = 0xbc9b,
        .time_high_and_version = 0x4821,
        .clock_seq_high_and_reserved = 0x80,
        .clock_seq_low = 0x8d,
        .node = [_]u8{ 0xec, 0x9e, 0xc4, 0x21, 0xa1, 0xa0 },
    };
};

const EfiBlockMedia = extern struct {
    media_id: u32,

    removable_media: bool,
    media_present: bool,
    logical_partition: bool,
    read_only: bool,
    write_caching: bool,

    block_size: u32,
    io_align: u32,
    last_block: Lba,

    // Revision 2
    lowest_aligned_lba: Lba,
    logical_blocks_per_physical_block: u32,
    optimal_transfer_length_granularity: u32,
};

const BlockIoProtocol = extern struct {
    const Self = @This();

    revision: u64,
    media: *EfiBlockMedia,

    _reset: fn (*BlockIoProtocol, extended_verification: bool) callconv(.C) Status,
    _read_blocks: fn (*BlockIoProtocol, media_id: u32, lba: Lba, buffer_size: usize, buf: [*]u8) callconv(.C) Status,
    _write_blocks: fn (*BlockIoProtocol, media_id: u32, lba: Lba, buffer_size: usize, buf: [*]u8) callconv(.C) Status,
    _flush_blocks: fn (*BlockIoProtocol) callconv(.C) Status,

    pub fn reset(self: *Self, extended_verification: bool) Status {
        return self._reset(self, extended_verification);
    }

    pub fn read_blocks(self: *Self, media_id: u32, lba: Lba, buffer_size: usize, buf: [*]u8) Status {
        return self._read_blocks(self, media_id, lba, buffer_size, buf);
    }

    pub fn write_blocks(self: *Self, media_id: u32, lba: Lba, buffer_size: usize, buf: [*]u8) Status {
        return self._write_blocks(self, media_id, lba, buffer_size, buf);
    }

    pub fn flush_blocks(self: *Self) Status {
        return self._flush_blocks(self);
    }

    // { 03 79 BE 4E - D7 06 - 43 7d - B0 37 -ED B8 2F B7 72 A4}
    pub const guid align(8) = uefi.Guid{
        .time_low = 0x964e5b21,
        .time_mid = 0x6459,
        .time_high_and_version = 0x11d2,
        .clock_seq_high_and_reserved = 0x8e,
        .clock_seq_low = 0x39,
        .node = [_]u8{ 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b },
    };
};

const KernelLoader = struct {
    loader: Loader,
    root: []const u16,
    initrd: []const u16,
    alloc: Allocator,

    pub fn load(self_opaque: *const anyopaque) Loader.LoaderError!void {
        var self = @ptrCast(
            *const KernelLoader,
            @alignCast(@alignOf(KernelLoader), self_opaque),
        );

        // maybe pool?
        var args = try std.mem.concat(self.alloc, u16, &[_][]const u16{
            utf16_str("ro root="),
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

pub fn parse_gpt_header(alloc: Allocator, entries: *GuidNameMap, buf: []u8, block_size: u32) !void {
    const mbr_magic = 0xaa55;
    const gpt_indicator = 0xee;
    const gpt_magic = 0x5452415020494645;
    const unused_entry_guid = std.mem.zeroes(uefi.Guid);

    var mbr = @ptrCast(*MasterBootRecord, buf.ptr);

    if (mbr.signature != mbr_magic or mbr.partitions[0].os_indicator != gpt_indicator) {
        return;
    }

    var gpt = @ptrCast(*GptHeader, buf.ptr + @sizeOf(MasterBootRecord));

    if (gpt.signature != gpt_magic) {
        return;
    }

    var parts = @ptrCast(*EfiPartitionEntry, buf.ptr + gpt.partition_entry_lba * block_size);

    var cnt = gpt.entry_count;
    while (cnt != 0) : (cnt -= 1) {
        var part = parts.*;
        defer parts = @ptrCast(*EfiPartitionEntry, @ptrCast([*]u8, parts) + gpt.entry_size);

        if (part.partition_type.eql(unused_entry_guid))
            break;

        var slice = std.mem.sliceTo(@alignCast(2, &parts.partition_name), 0);

        var name: [:0]const u16 = blk: {
            if (slice.len > 0 and slice.len < part.partition_name.len) {
                break :blk try alloc.dupeZ(u16, slice);
            } else {
                break :blk try alloc.dupeZ(u16, utf16_str("unknown"));
            }
        };

        try entries.put(part.partition_uuid, name);
    }
}

pub fn find_roots(alloc: Allocator) !GuidNameMap {
    var handles = blk: {
        var handle_ptr: [*]uefi.Handle = undefined;
        var res_size: usize = undefined;

        try boot_services.locateHandleBuffer(
            .ByProtocol,
            &BlockIoProtocol.guid,
            null,
            &res_size,
            &handle_ptr,
        ).err();

        break :blk handle_ptr[0..res_size];
    };
    defer uefi.raw_pool_allocator.free(handles);

    var entries = GuidNameMap.init(alloc);

    try out.printf("got {} handles\r\n", .{handles.len});

    for (handles) |handle| {
        var blk_io = boot_services.openProtocolSt(BlockIoProtocol, handle) catch unreachable;

        var blk_media = blk_io.media;

        var buf: [2048]u8 = undefined;

        blk_io.read_blocks(blk_media.media_id, 0, buf.len, &buf).err() catch {
            continue;
        };

        try parse_gpt_header(alloc, &entries, &buf, blk_media.block_size);
    }

    return entries;
}

pub fn load_args(
    alloc: Allocator,
    fp: *const FileProtocol,
    kernel: [:0]u16,
    init: []const u16,
) ![]u16 {
    var conf = try read_conf(alloc, fp, kernel[0..kernel.len]);
    var args = try std.mem.concat(alloc, u16, &[_][]const u16{
        conf,
        utf16_str(" initrd="),
        init,
        &[_]u16{0},
    });

    return args;
}

pub fn find_kernels(
    alloc: Allocator,
    li: *std.ArrayList(Loader),
    entries: *std.ArrayList(Menu(main.MenuError).MenuEntry),
    fp: *const FileProtocol,
    disk_info: DiskInfo,
    buf: []align(8) u8,
) !void {
    try _find_kernels(alloc, li, entries, fp, disk_info, buf);

    var boot_fp: *FileProtocol = undefined;

    // Check /boot if it exists for stuff like an ext4 partition
    fp.open(&boot_fp, utf16_str("boot"), FileProtocol.efi_file_mode_read, 0).err() catch {
        return;
    };

    try _find_kernels(alloc, li, entries, boot_fp, disk_info, buf);
}

fn _find_kernels(
    alloc: Allocator,
    li: *std.ArrayList(Loader),
    entries: *std.ArrayList(Menu(main.MenuError).MenuEntry),
    fp: *const FileProtocol,
    disk_info: DiskInfo,
    buf: []align(8) u8,
) !void {
    var roots = try find_roots(alloc);

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

            var init = find_initrd(alloc, fp, name) catch {
                continue;
            };
            defer alloc.free(init);

            var loaded_args = load_args(alloc, fp, kernel, init) catch null;

            // If we have args, use them
            if (loaded_args) |args| {
                try li.append(Loader{
                    .disk_info = disk_info,
                    .file_name = kernel,
                    .args = args[0 .. args.len - 1 :0],
                });

                continue;
            }

            // Otherwise, create a menu to choose from possible root disks
            const KernelMenu = Menu(main.MenuError);
            const MenuEntry = KernelMenu.MenuEntry;

            var disk_entries = std.ArrayList(MenuEntry).init(alloc);
            var internal_loader = Loader{
                .disk_info = disk_info,
                .file_name = kernel,
                .args = null,
            };

            var it = roots.iterator();
            while (it.next()) |v| {
                var guid16: [2048:0]u16 = undefined;
                var guid_buf: [2048]u8 = undefined;

                var guid8 = try std.fmt.bufPrint(&guid_buf, "{}", .{v.key_ptr.*});
                var ind = try std.unicode.utf8ToUtf16Le(&guid16, guid8);

                var desc = try std.mem.concat(alloc, u16, &[_][]const u16{
                    v.value_ptr.*,
                    utf16_str(": "),
                    guid16[0..ind],
                    &[_]u16{0},
                });

                var guid16_alloc = try alloc.dupeZ(u16, guid16[0..ind]);

                var loader = try alloc.create(KernelLoader);
                loader.* = KernelLoader{
                    .loader = internal_loader,
                    .root = guid16_alloc,
                    .initrd = init,
                    .alloc = alloc,
                };

                try disk_entries.append(MenuEntry{
                    .description = desc[0 .. desc.len - 1 :0],
                    .callback = .{ .WithData = .{
                        .fun = KernelLoader.load,
                        .data = loader,
                    } },
                });
            }

            var menu = try alloc.create(KernelMenu);
            menu.* = KernelMenu.init(
                disk_entries.toOwnedSlice(),
                Output{ .con = uefi.system_table.con_out.? },
                uefi.system_table.con_in.?,
            );

            const MenuRunner = struct {
                pub fn run_menu(opaque_ptr: *anyopaque) main.MenuError!void {
                    var menu_ptr = @ptrCast(*KernelMenu, @alignCast(@alignOf(KernelMenu), opaque_ptr));

                    try menu_ptr.run();
                }
            };

            _ = MenuRunner;

            try entries.append(MenuEntry{
                .description = kernel,
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
