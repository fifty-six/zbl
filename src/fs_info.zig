const std = @import("std");
const uefi = std.os.uefi;
const Guid = uefi.Guid;

pub const FileSystemInfo = extern struct {
    const Self = @This();

    size: u64,
    read_only: bool,
    volume_size: u64,
    free_space: u64,
    block_size: u32,
    _volume_label: u16,

    pub fn getVolumeLabel(self: *const Self) [*:0]const u16 {
        return @as([*:0]const u16, @ptrCast(&self._volume_label));
    }

    pub const guid align(8) = Guid{
        .time_low = 0x09576e93,
        .time_mid = 0x6d3f,
        .time_high_and_version = 0x11d2,
        .clock_seq_high_and_reserved = 0x8e,
        .clock_seq_low = 0x39,
        .node = [_]u8{ 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b },
    };
};
