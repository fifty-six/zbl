const std = @import("std");
const uefi = std.os.uefi;

const panic = @import("panic.zig");
const output = @import("output.zig");

const Output = output.Output;

pub fn text() void {
    _text() catch {};
}

fn _text() !void {
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;
    const con_out = sys_table.con_out.?;
    const con_in = sys_table.con_in.?;
    const out = Output{ .con = con_out };

    const input_events = [_]uefi.Event{con_in.wait_for_key};

    try out.reset(false);

    _ = con_out.setCursorPosition(0, 0);

    var index: usize = undefined;
    while (boot_services.waitForEvent(input_events.len, &input_events, &index) == .Success) {
        if (index != 0) {
            @panic("invalid index");
        }

        var key: uefi.protocols.InputKey = undefined;
        if (con_in.readKeyStroke(&key) != .Success)
            continue;

        if (key.scan_code == 0x17) {
            panic.die(.Success);
        } else if (key.unicode_char != 0) {
            try out.putchar(key.unicode_char);
        }
    }
}
