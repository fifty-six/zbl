const std = @import("std");
const uefi = std.os.uefi;
const protocols = uefi.protocols;
const panic_handler = @import("panic.zig");

const Status = uefi.Status;
const Output = @import("output.zig").Output;

pub const MenuEntry = struct { description: []const u8, callback: fn () void };

const Vec = struct { x: usize, y: usize };

pub const Menu = struct {
    entries: []const MenuEntry,
    out: Output,
    in: *In,

    _res: Vec,
    _highlighted: usize,

    const ConOut = protocols.SimpleTextOutputProtocol;
    const In = protocols.SimpleTextInputProtocol;

    pub fn init(entries: []const MenuEntry, out: Output, in: *In) Menu {
        var self = Menu{
            .entries = entries,
            .out = out,
            .in = in,
            ._highlighted = 0,
            ._res = Vec{ .x = 0, .y = 0 },
        };

        _ = out.con.queryMode(out.con.mode.mode, &self._res.x, &self._res.y);

        return self;
    }

    pub fn run(self: *Menu) !MenuEntry {
        try self.draw();

        const boot_services = uefi.system_table.boot_services.?;

        const input_events = [_]uefi.Event{self.in.wait_for_key};

        var index: usize = undefined;
        while (boot_services.waitForEvent(input_events.len, &input_events, &index) == .Success) {
            if (index != 0) {
                @panic("received invalid index");
            }

            var key: protocols.InputKey = undefined;
            if (self.in.readKeyStroke(&key) != .Success)
                return error.FailedToReadKey;

            switch (key.scan_code) {
                // Up/Down arrow
                0x01...0x02 => {
                    // 1 (Up) -> -1, 2 (Down) -> 1
                    // -2 [1, 2] + 3 -> [-2, -4] + 3 -> [1, -1]
                    // 2 [1, 2] -> [2, 4] -> [-1, 1]
                    var shift = 2 * @intCast(i8, key.scan_code) - 3;

                    self._highlighted = if (self._highlighted == 0 and shift < 0)
                        self.entries.len - @intCast(u8, -shift)
                    else
                        @intCast(usize, (@intCast(isize, self._highlighted) + shift)) % self.entries.len;
                },

                // Escape
                0x17 => {
                    panic_handler.die(.Success);
                },

                else => {},
            }

            switch (key.unicode_char) {
                // Enter
                0x0D => return self.entries[self._highlighted],

                else => {},
            }

            try self.draw();
        }

        unreachable;
    }

    pub fn draw(self: *const Menu) !void {
        // Clear our screen
        try self.out.reset(false);

        var center = Vec{ .x = @divFloor(self._res.x, 2), .y = @divFloor(self._res.y, 2) };

        center.y -= @divFloor(self.entries.len, 2);

        for (self.entries) |entry, i| {
            var start = center.x - @divFloor(entry.description.len, 2);

            try self.out.setCursorPosition(start, center.y + i);

            if (self._highlighted == i) {
                _ = self.out.con.setAttribute(ConOut.background_lightgray | ConOut.black);
            } else {
                _ = self.out.con.setAttribute(ConOut.background_black | ConOut.white);
            }

            try self.out.printf("{s}\r\n", .{entry.description});
        }

        _ = self.out.con.setAttribute(ConOut.background_black | ConOut.white);
        try self.out.println("");
    }
};
