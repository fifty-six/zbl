const std = @import("std");
const uefi = std.os.uefi;
const protocols = uefi.protocol;

const DevicePathProtocol = protocols.DevicePath;
const FilePathDevicePath = uefi.DevicePath.Media.FilePathDevicePath;
const EndEntireDevicePath = uefi.DevicePath.End.EndEntireDevicePath;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

const tag_to_utf16_literal = init: {
    @setEvalBranchQuota(10000);
    const KV = struct { @"0": []const u8, @"1": []const u16 };

    const enums = [_]type{
        protocols.MediaDevicePath.Subtype,
        protocols.HardwareDevicePath.Subtype,
        protocols.DevicePathType,
    };

    var kv: []const KV = &.{};

    for (enums) |e| {
        const fields = @typeInfo(e).Enum.fields;

        for (fields) |field| {
            kv = kv ++ &[_]KV{.{
                .@"0" = field.name,
                .@"1" = utf16_str(field.name),
            }};
        }
    }

    const map = std.ComptimeStringMap([]const u16, kv);

    break :init map;
};

pub fn dpp_size(dpp: *DevicePathProtocol) usize {
    const start = dpp;

    var node = dpp;
    while (node.type != .end) {
        node = @as(*DevicePathProtocol, @ptrCast(@as([*]u8, @ptrCast(node)) + node.length));
    }

    return (@intFromPtr(node) + node.length) - @intFromPtr(start);
}

pub fn file_path(
    alloc: std.mem.Allocator,
    dpp: *DevicePathProtocol,
    path: [:0]const u16,
) !*DevicePathProtocol {
    const size = dpp_size(dpp);

    // u16 of path + null terminator -> 2 * (path.len + 1)
    const buf = try alloc.alloc(u8, size + 2 * (path.len + 1) + @sizeOf(DevicePathProtocol));

    @memcpy(buf[0..size], @as([*]u8, @ptrCast(dpp))[0..size]);

    // Pointer to the start of the protocol, which is - 4 as the size includes the node length field.
    var new_dpp = @as(*FilePathDevicePath, @ptrCast(buf.ptr + size - 4));

    new_dpp.type = .media;
    new_dpp.subtype = .file_path;
    new_dpp.length = @sizeOf(FilePathDevicePath) + 2 * (@as(u16, @intCast(path.len)) + 1);

    var ptr = @as([*:0]u16, @ptrCast(@as([*]align(2) u8, @alignCast(@ptrCast(new_dpp))) + @sizeOf(FilePathDevicePath)));

    for (path, 0..) |s, i|
        ptr[i] = s;

    ptr[path.len] = 0;

    var next = @as(*EndEntireDevicePath, @ptrCast(@as([*]u8, @ptrCast(new_dpp)) + new_dpp.length));
    next.type = .end;
    next.subtype = .end_entire;
    next.length = @sizeOf(EndEntireDevicePath);

    return @as(*DevicePathProtocol, @ptrCast(buf.ptr));
}

pub fn to_str(alloc: std.mem.Allocator, dpp: *DevicePathProtocol) ![:0]u16 {
    var res = std.ArrayList(u16).init(alloc);
    errdefer res.deinit();

    var node = dpp;
    while (node.type != .end) {
        const q_path = node.getDevicePath();

        // Unhandled upstream, just append the tag name.
        if (q_path == null) {
            try res.appendSlice(tag_to_utf16_literal.get(@tagName(node.type)).?);
            try res.append('\\');
            node = @as(@TypeOf(node), @ptrCast(@as([*]u8, @ptrCast(node)) + node.length));
            continue;
        }

        const path = q_path.?;

        switch (path) {
            .hardware => |hw| {
                try res.appendSlice(tag_to_utf16_literal.get(@tagName(hw)).?);
            },
            .media => |m| {
                switch (m) {
                    .FilePath => |fp| {
                        try res.appendSlice(std.mem.span(fp.getPath()));
                    },
                    else => {
                        try res.appendSlice(tag_to_utf16_literal.get(@tagName(m)).?);
                    },
                }
            },
            .messaging, .acpi => {
                // TODO: upstream
            },
            // We're adding a backslash after anyways, so use that.
            .end => {},
            else => {
                try res.append('?');
            },
        }

        try res.append('\\');

        node = @as(@TypeOf(node), @ptrCast(@as([*]u8, @ptrCast(node)) + node.length));
    }

    return try res.toOwnedSliceSentinel(0);
}
