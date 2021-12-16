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

var alloc_bytes: [100 * 1024]u8 = undefined;
var alloc_state = std.heap.FixedBufferAllocator.init(&panic_allocator_bytes);
const fixed_alloc = &alloc_state.allocator;

var sys_table: *uefi.tables.SystemTable = undefined;
var boot_services: *uefi.tables.BootServices = undefined;
var con_in: *protocols.SimpleTextInputProtocol = undefined;
var con_out: *protocols.SimpleTextOutputProtocol = undefined;
var out: Output = undefined;

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

pub fn full_device_path(dpp: *protocols.DevicePathProtocol) anyerror!void {
    if (dpp.type == .Media) {
        var subtype = @intToEnum(protocols.MediaDevicePath.Subtype, dpp.subtype);
        if (subtype == .FilePath) {
            try out.print16(dpp.getDevicePath().?.Media.FilePath.getPath());
            try out.print("\r\n");
        } else {
            try out.printf("Unhandled .Media {s}\r\n", .{@tagName(subtype)});
        }
    } else {
        try out.printf("Node: {s}\r\n", .{@tagName(dpp.type)});
    }

    if (dpp.type == .End) {
        var subtype = @intToEnum(protocols.EndDevicePath.Subtype, dpp.subtype);
        try out.printf("End: {s}\r\n", .{@tagName(subtype)});
        return;
    }

    var len = 4 + @intCast(u8, dpp.length >> 8);

    try out.printf("Length: {d}\r\n", .{len});

    var new_dpp = @intToPtr(*protocols.DevicePathProtocol, @ptrToInt(dpp) + len);

    try full_device_path(new_dpp);
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
    try out.println("hi");

    // Wait to say hi.
    _ = boot_services.stall(1 * 1000 * 1000);

    try out.reset(false);

    const image = uefi.handle;

    var sfp = try open_protocol(image, protocols.LoadedImageProtocol);
    var file_protocol = try open_protocol(sfp.*.device_handle.?, protocols.SimpleFileSystemProtocol);

    try out.printf("{s}\r\n", .{@tagName(sfp.file_path.type)});
    try out.printf("{s}\r\n", .{@tagName(@intToEnum(protocols.MediaDevicePath.Subtype, sfp.file_path.subtype))});

    // bro what else would it be
    if (sfp.file_path.type != .Media)
        return error.ImageFilePathNotMedia;

    if (@intToEnum(protocols.MediaDevicePath.Subtype, sfp.file_path.subtype) != .FilePath)
        return error.DeviceHandleNotAtFilePath;

    try full_device_path(sfp.file_path);
    // try out.print16(sfp.file_path.getDevicePath().?.Media.FilePath.getPath());
    // try out.print("\r\n");

    _ = boot_services.stall(5 * 1000 * 1000);

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
