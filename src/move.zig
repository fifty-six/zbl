const std = @import("std");
const uefi = std.os.uefi;

const panic = @import("panic.zig");
const output = @import("output.zig");

const Output = output.Output;

pub fn move() void {
    _move() catch return;
}

fn _move() !void {
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;
    const con_out = sys_table.con_out.?;
    const con_in = sys_table.con_in.?;
    const out = Output{ .con = con_out };

    var res_x: usize = undefined;
    var res_y: usize = undefined;
    _ = con_out.queryMode(con_out.mode.mode, &res_x, &res_y);

    var cursor_x: usize = 0;
    var cursor_y: usize = 0;

    try out.reset(false);

    _ = con_out.setCursorPosition(0, 0);

    const input_events = [_]uefi.Event{con_in.wait_for_key};

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
        }

        if (key.unicode_char != 0) {
            try out.putchar(key.unicode_char);
        }

        // Note that the position is (0, 0) at the top
        // and down for +y, right for +x
        if (key.scan_code >= 1 and key.scan_code <= 4) {
            _ = con_out.setCursorPosition(cursor_x, cursor_y);
            try out.print(" ");

            if (key.scan_code == 3 or key.scan_code == 4) {
                var offset: i8 = -2 * (@intCast(i8, key.scan_code) - 3) + 1;

                if (offset > 0 or cursor_x >= 1)
                    cursor_x = @intCast(usize, @intCast(isize, cursor_x) + offset);

                if (offset < 0 and cursor_x == 0)
                    cursor_x = res_x - 1;
            }

            if (key.scan_code == 1 or key.scan_code == 2) {
                var offset: i8 = 2 * (@intCast(i8, key.scan_code) - 1) - 1;

                if (offset > 0 or cursor_y >= 1)
                    cursor_y = @intCast(usize, @intCast(isize, cursor_y) + offset);

                if (offset < 0 and cursor_y == 0)
                    cursor_y = res_y - 1;
            }

            cursor_x %= res_x;
            cursor_y %= res_y;

            _ = con_out.setCursorPosition(cursor_x, cursor_y);
            try out.print("#");
        }
    }
}
