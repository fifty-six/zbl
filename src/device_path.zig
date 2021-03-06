const std = @import("std");
const uefi = std.os.uefi;
const protocols = uefi.protocols;

const DevicePathProtocol = protocols.DevicePathProtocol;
const FilePathDevicePath = protocols.MediaDevicePath.FilePathDevicePath;
const EndEntireDevicePath = protocols.EndDevicePath.EndEntireDevicePath;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

const tag_to_utf16_literal = init: {
    @setEvalBranchQuota(10000);
    const KV = struct { @"0": []const u8, @"1": []const u16 };

    comptime var enums = [_]type{
        protocols.MediaDevicePath.Subtype,
        protocols.HardwareDevicePath.Subtype,
        protocols.DevicePathType,
    };

    comptime var kv: []const KV = &.{};

    inline for (enums) |e| {
        comptime var fields = @typeInfo(e).Enum.fields;

        inline for (fields) |field| {
            kv = kv ++ &[_]KV{.{
                .@"0" = field.name,
                .@"1" = utf16_str(field.name),
            }};
        }
    }

    comptime var map = std.ComptimeStringMap([]const u16, kv);

    break :init map;
};

pub fn dpp_size(dpp: *DevicePathProtocol) usize {
    var start = dpp;

    var node = dpp;
    while (node.type != .End) {
        node = @ptrCast(*DevicePathProtocol, @ptrCast([*]u8, node) + node.length);
    }

    return (@ptrToInt(node) + node.length) - @ptrToInt(start);
}

pub fn file_path(
    alloc: std.mem.Allocator,
    dpp: *DevicePathProtocol,
    path: [:0]const u16,
) !*DevicePathProtocol {
    var size = dpp_size(dpp);

    // u16 of path + null terminator -> 2 * (path.len + 1)
    var buf = try alloc.alloc(u8, size + 2 * (path.len + 1) + @sizeOf(DevicePathProtocol));

    std.mem.copy(u8, buf, @ptrCast([*]u8, dpp)[0..size]);

    // Pointer to the start of the protocol, which is - 4 as the size includes the node length field.
    var new_dpp = @ptrCast(*FilePathDevicePath, buf.ptr + size - 4);

    new_dpp.type = .Media;
    new_dpp.subtype = .FilePath;
    new_dpp.length = @sizeOf(FilePathDevicePath) + 2 * (@intCast(u16, path.len) + 1);

    var ptr = @ptrCast([*:0]u16, @alignCast(2, @ptrCast([*]u8, new_dpp)) + @sizeOf(FilePathDevicePath));

    for (path) |s, i|
        ptr[i] = s;

    ptr[path.len] = 0;

    var next = @ptrCast(*EndEntireDevicePath, @ptrCast([*]u8, new_dpp) + new_dpp.length);
    next.type = .End;
    next.subtype = .EndEntire;
    next.length = @sizeOf(EndEntireDevicePath);

    return @ptrCast(*DevicePathProtocol, buf.ptr);
}

pub fn to_str(alloc: std.mem.Allocator, dpp: *DevicePathProtocol) ![:0]u16 {
    var res = std.ArrayList(u16).init(alloc);
    errdefer res.deinit();

    var node = dpp;
    while (node.type != .End) {
        var q_path = node.getDevicePath();

        // Unhandled upstream, just append the tag name.
        if (q_path == null) {
            try res.appendSlice(tag_to_utf16_literal.get(@tagName(node.type)).?);
            try res.append('\\');
            node = @ptrCast(@TypeOf(node), @ptrCast([*]u8, node) + node.length);
            continue;
        }

        var path = q_path.?;

        switch (path) {
            .Hardware => |hw| {
                try res.appendSlice(tag_to_utf16_literal.get(@tagName(hw)).?);
            },
            .Media => |m| {
                switch (m) {
                    .FilePath => |fp| {
                        try res.appendSlice(std.mem.span(fp.getPath()));
                    },
                    else => {
                        try res.appendSlice(tag_to_utf16_literal.get(@tagName(m)).?);
                    },
                }
            },
            .Messaging, .Acpi => {
                // TODO: upstream
            },
            // We're adding a backslash after anyways, so use that.
            .End => {},
            else => {
                try res.append('?');
            },
        }

        try res.append('\\');

        node = @ptrCast(@TypeOf(node), @ptrCast([*]u8, node) + node.length);
    }

    return try res.toOwnedSliceSentinel(0);
}
