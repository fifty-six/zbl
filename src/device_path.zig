const std = @import("std");
const uefi = std.os.uefi;
const protocols = uefi.protocols;

const MediaDevicePath = protocols.MediaDevicePath;
const DevicePathProtocol = protocols.DevicePathProtocol;

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
        node = @intToPtr(*DevicePathProtocol, @ptrToInt(node) + node.length);
    }

    return (@ptrToInt(node) + node.length) - @ptrToInt(start);
}

pub fn file_path(
    alloc: std.mem.Allocator,
    dpp: *DevicePathProtocol,
    path: [:0]const u16,
) !*DevicePathProtocol {
    var size = dpp_size(dpp);

    var buf = try alloc.alloc(u8, size + path.len + 1 + @sizeOf(DevicePathProtocol));

    std.mem.copy(u8, buf, @ptrCast([*]u8, dpp)[0..size]);

    var new_dpp = @intToPtr(*DevicePathProtocol, @ptrToInt(buf.ptr) + size - 4);

    new_dpp.type = .Media;
    new_dpp.subtype = @enumToInt(MediaDevicePath.Subtype.FilePath);
    new_dpp.length = 4 + 2 * (@intCast(u16, path.len) + 1);

    var ptr = @ptrCast(
        [*:0]u16,
        @alignCast(2, @ptrCast([*]u8, new_dpp)) + @sizeOf(MediaDevicePath.FilePathDevicePath),
    );

    for (path) |s, i|
        ptr[i] = s;

    ptr[path.len] = 0;

    var next = @intToPtr(*DevicePathProtocol, @ptrToInt(new_dpp) + new_dpp.length);
    next.type = .End;
    next.subtype = @enumToInt(protocols.EndDevicePath.EndEntire);
    next.length = 4;

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
            node = @intToPtr(@TypeOf(node), @ptrToInt(node) + node.length);
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

        node = @intToPtr(@TypeOf(node), @ptrToInt(node) + node.length);
    }

    return try res.toOwnedSliceSentinel(0);
}
