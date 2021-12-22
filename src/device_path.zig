const std = @import("std");
const uefi = std.os.uefi;
const protocols = uefi.protocols;

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

pub fn to_str(alloc: std.mem.Allocator, dpp: *protocols.DevicePathProtocol) ![:0]u16 {
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
