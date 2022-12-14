const std = @import("std");
const builtin = @import("builtin");

const main = @import("main.zig");
const Output = @import("Output.zig");

const uefi = std.os.uefi;
const BlockIoProtocol = std.os.uefi.protocols.BlockIoProtocol;

const Allocator = std.mem.Allocator;
const Status = uefi.Status;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

const Loader = main.Loader;
const DiskInfo = main.DiskInfo;

extern var boot_services: *uefi.tables.BootServices;

var out = &main.out;

const Lba = u64;

pub const GuidNameMap = std.AutoHashMap(uefi.Guid, [:0]const u16);

const MbrPartitionRecord = extern struct {
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

const MasterBootRecord = extern struct {
    boot_code: [440]u8,
    unique_signature: [4]u8,
    unknown: [2]u8,
    partitions: [4]MbrPartitionRecord,
    signature: u16,
};

const GptHeader = extern struct {
    signature: u64 align(1),

    revision: u32 align(1),
    header_size: u32 align(1),
    header_crc32: u32 align(1),
    reserved: u32 align(1),

    my_lba: Lba align(1),
    alternate_lba: Lba align(1),
    first_usable_lba: Lba align(1),
    last_usable_lba: Lba align(1),

    disk_guid: uefi.Guid align(1),

    partition_entry_lba: Lba align(1),
    entry_count: u32 align(1),
    entry_size: u32 align(1),
    parts_crc32: u32 align(1),
};

const EfiPartitionEntry = extern struct {
    partition_type: uefi.Guid align(1),
    partition_uuid: uefi.Guid align(1),

    starting_lba: Lba align(1),
    ending_lba: Lba align(1),

    attributes: u64 align(1),
    partition_name: [36]u16 align(1),
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

pub fn parse_gpt_header(alloc: Allocator, entries: *GuidNameMap, buf: []u8, block_size: u32) !void {
    const mbr_magic = 0xaa55;
    const gpt_indicator = 0xee;
    const gpt_magic = 0x5452415020494645;
    const unused_entry_guid = std.mem.zeroes(uefi.Guid);

    var mbr = @ptrCast(*MasterBootRecord, @alignCast(2, buf.ptr));

    if (mbr.signature != mbr_magic or mbr.partitions[0].os_indicator != gpt_indicator) {
        return;
    }

    var gpt = @ptrCast(*GptHeader, buf.ptr + @sizeOf(MasterBootRecord));

    if (gpt.signature != gpt_magic) {
        return;
    }

    var parts = @ptrCast(*EfiPartitionEntry, buf.ptr + gpt.partition_entry_lba * block_size);

    const kb = 1024;
    const mb = 1024 * kb;
    const gb = 1024 * mb;

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
                var fmt: [100]u8 = undefined;

                var diff: u64 = undefined;
                var bytes: u64 = undefined;

                if (@subWithOverflow(u64, part.ending_lba, part.starting_lba, &diff))
                    break :blk try alloc.dupeZ(u16, utf16_str("unknown - ending_lba < starting_lba"));

                if (@mulWithOverflow(u64, diff, block_size, &bytes))
                    break :blk try alloc.dupeZ(u16, utf16_str("unknown - unknown size (mul overflow)"));

                const Size = struct {
                    size: u64,
                    str: []const u8,
                };

                var size: Size = switch (bytes) {
                    0...(kb - 1) => .{ .size = bytes, .str = " bytes" },
                    kb...(mb - 1) => .{ .size = @divFloor(bytes, kb), .str = "KiB" },
                    mb...gb => .{ .size = @divFloor(bytes, mb), .str = "MiB" },
                    else => .{ .size = @divFloor(bytes, gb), .str = "GiB" },
                };

                var res = try std.fmt.bufPrint(&fmt, "unknown {}{s} volume", size);

                break :blk try std.unicode.utf8ToUtf16LeWithNull(alloc, res);
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

    for (handles) |handle| {
        var blk_io = boot_services.openProtocolSt(BlockIoProtocol, handle) catch {
            continue;
        };

        var blk_media = blk_io.media;

        var buf: [2048]u8 = undefined;

        blk_io.readBlocks(blk_media.media_id, 0, buf.len, &buf).err() catch {
            continue;
        };

        try parse_gpt_header(alloc, &entries, &buf, blk_media.block_size);
    }

    return entries;
}
