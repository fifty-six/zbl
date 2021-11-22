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

pub fn fail_if_err(st: Status, comptime msg: []const u8) void {
    if (st != .Success)
        @panic(msg);
}

pub fn main() void {
    caught_main() catch unreachable;
}

pub fn caught_main() !void {
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;
    const con_out = sys_table.con_out.?;
    const con_in = sys_table.con_in.?;
    const out = Output{ .con = con_out };

    try out.reset(false);
    try out.println("hi");

    // Wait to say hi.
    _ = boot_services.stall(1 * 1000 * 1000);

    try out.reset(false);

    var image = uefi.handle;
    var sfp: ?*protocols.LoadedImageProtocol = undefined;
    var attrs = uefi.tables.OpenProtocolAttributes{
        .by_handle_protocol = true,
    };

    if (boot_services.openProtocol(image, &protocols.LoadedImageProtocol.guid, @ptrCast(*?*c_void, &sfp), image, null, attrs) != .Success)
        return error.FailedToOpenLoadedImageProtocol;

    var path_protocol = sfp.?.file_path.*;

    var path = path_protocol.getDevicePath();

    if (path_protocol.type != .Media)
        return error.PathProtocolNotMedia;

    var subtype = @intToEnum(protocols.MediaDevicePath.Subtype, path_protocol.subtype);
    var subtype_str: []const u8 = undefined;

    inline for (@typeInfo(protocols.MediaDevicePath.Subtype).Enum.fields) |field| {
        if (path_protocol.subtype == field.value)
            subtype_str = field.name;
    }

    try out.printf("{s}\r\n", .{subtype_str});

    if (subtype == .FilePath) {
        var path_str = path.?.Media.FilePath.getPath();
        var buf = std.mem.spanZ(path_str);

        try out.printf("len = {}\r\n", .{buf.len});

        try out.print16(path_str);
        try out.println("");
    }

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
