const std = @import("std");
const uefi = std.os.uefi;

const protocols = uefi.protocols;
const Status = uefi.Status;

const menus = @import("menu.zig");
const output = @import("output.zig");
const move = @import("move.zig");
const text = @import("text.zig");

const Output = output.Output;

const Menu = menus.Menu;
const MenuEntry = menus.MenuEntry;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

var alloc_bytes: [100 * 1024]u8 = undefined;
var alloc_state = std.heap.FixedBufferAllocator.init(&alloc_bytes);
const fixed_alloc = &alloc_state.allocator;

var sys_table: *uefi.tables.SystemTable = undefined;
var boot_services: *uefi.tables.BootServices = undefined;
var con_in: *protocols.SimpleTextInputProtocol = undefined;
var con_out: *protocols.SimpleTextOutputProtocol = undefined;
var out: Output = undefined;

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

pub fn open_protocol(handle: uefi.Handle, comptime protocol: type) !*protocol {
    var ptr: *protocol = undefined;
    if (boot_services.openProtocol(
        handle,
        &protocol.guid,
        @ptrCast(*?*c_void, &ptr),
        uefi.handle,
        null,
        uefi.tables.OpenProtocolAttributes{ .by_handle_protocol = true },
    ) != .Success) {
        return error.FailedToOpenProtocol;
    }

    return ptr;
}

const FullDevicePathErr = error{
    DeviceError,
    Unsupported,
    UnknownGlyph,
};

pub fn device_path_to_str(alloc: *std.mem.Allocator, dpp: *protocols.DevicePathProtocol) ![:0]u16 {
    var res = std.ArrayList(u16).init(alloc);
    errdefer res.deinit();

    var utf16: [256]u16 = undefined;

    var node = dpp;
    while (node.type != .End) {
        var path = node.getDevicePath() orelse return error.NoDevicePath;

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
            // Adding a backslash at the end anyways.
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

pub fn ls(fp: *const protocols.FileProtocol) !void {
    var buf: [4096]u8 align(8) = undefined;
    var size = buf.len;

    while (size != 0) {
        size = buf.len;

        if (fp.getInfo(&protocols.FileProtocol.guid, &size, &buf) != .Success)
            return error.InfoError;

        var file_info = @ptrCast(*protocols.FileInfo, &buf);

        comptime const efi_file_dir = protocols.FileInfo.efi_file_directory;

        try out.print16(file_info.getFileName());
        try out.printf("\r\nfileSize: {d}, physicalSize: {d}, attr: {x}, dir: {x} \r\n", .{
            file_info.file_size,
            file_info.physical_size,
            file_info.attribute,
            (file_info.attribute & efi_file_dir) == efi_file_dir,
        });

        size = buf.len;

        var res = fp.read(&size, &buf);
        if (res != .Success) {
            if (res == .BufferTooSmall) {
                try out.printf("size required is {d}\r\n", .{size});
                _ = boot_services.stall(5 * 1000 * 100);
            }
            return error.DiskError;
        }

        file_info = @ptrCast(*protocols.FileInfo, &buf);

        try out.print16(file_info.getFileName());

        _ = boot_services.stall(5 * 1000 * 100);
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

    const image = uefi.handle;

    var img_proto = try open_protocol(image, protocols.LoadedImageProtocol);
    var sfsp = try open_protocol(img_proto.*.device_handle.?, protocols.SimpleFileSystemProtocol);

    try out.print16(try device_path_to_str(fixed_alloc, img_proto.file_path));
    try out.print("\r\n");

    var fp: *const protocols.FileProtocol = undefined;

    if (sfsp.openVolume(&fp) != .Success)
        return error.UnableToOpenVolume;

    try ls(fp);

    _ = boot_services.stall(3 * 1000 * 1000);

    try out.reset(false);

    var entries = [_]MenuEntry{
        MenuEntry{ .description = "Move the cursor", .callback = move.move },
        MenuEntry{ .description = "Write some text", .callback = text.text },
        MenuEntry{ .description = "Exit", .callback = die_fast },
    };

    var menu = Menu.init(&entries, out, con_in);

    var entry = try menu.run();
    entry.callback();

    _ = boot_services.stall(5 * 1000 * 1000);

    unreachable;
}

const f_panic = @import("panic.zig");
pub fn panic(message: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
    f_panic.panic(message, trace);
}

pub fn die_fast() noreturn {
    f_panic.die(.Success);
}
