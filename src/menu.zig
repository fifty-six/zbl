const std = @import("std");
const uefi = std.os.uefi;
const protocols = uefi.protocol;
const panic_handler = @import("panic.zig");

const Status = uefi.Status;
const Output = @import("Output.zig");

pub const CallbackFun = union(enum) {
    Empty: *const fn () void,
    WithData: *const fn (?*align(8) const anyopaque) void,
};

const Vec = struct { x: usize, y: usize };

pub fn Menu(comptime err: type) type {
    return struct {
        const Self = @This();

        pub const MenuEntry = struct {
            const DataCallback = struct {
                fun: *const fn (*anyopaque) err!void,
                data: *anyopaque,
            };

            const Callback = union(enum) {
                Empty: *const fn () err!void,
                WithData: DataCallback,
            };

            description: [:0]const u16,
            callback: Callback,
        };

        entries: []const MenuEntry,
        out: Output,
        in: *In,

        _res: Vec,
        _highlighted: usize,

        const ConOut = protocols.SimpleTextOutput;
        const In = protocols.SimpleTextInput;

        pub fn init(entries: []const MenuEntry, out: Output, in: *In) Self {
            var self = Self{
                .entries = entries,
                .out = out,
                .in = in,
                ._highlighted = 0,
                ._res = Vec{ .x = 0, .y = 0 },
            };

            _ = out.con.queryMode(out.con.mode.mode, &self._res.x, &self._res.y);

            return self;
        }

        pub fn run(self: *Self) !void {
            while (true) {
                const entry = try self.next();

                const callback_error = switch (entry.callback) {
                    .WithData => |info| blk: {
                        break :blk info.fun(info.data);
                    },
                    .Empty => |fun| blk: {
                        break :blk fun();
                    },
                };

                callback_error catch |e| {
                    try self.out.reset(false);

                    try self.out.printf("error in menu callback: {s}\r\n", .{@errorName(e)});
                    _ = @import("main.zig").boot_services.stall(1000 * 1000);

                    try self.out.reset(false);
                    continue;
                };

                unreachable;
            }
        }

        pub fn next(self: *Self) !Self.MenuEntry {
            try self.draw();

            const boot_services = uefi.system_table.boot_services.?;

            const input_events = [_]uefi.Event{self.in.wait_for_key};

            var index: usize = undefined;
            while (boot_services.waitForEvent(input_events.len, &input_events, &index) == .Success) {
                if (index != 0) {
                    @panic("received invalid index");
                }

                var key: In.Key.Input = undefined;
                if (self.in.readKeyStroke(&key) != .Success)
                    return error.FailedToReadKey;

                switch (key.scan_code) {
                    // Up/Down arrow
                    0x01...0x02 => {
                        // 1 (Up) -> -1, 2 (Down) -> 1
                        // -2 [1, 2] + 3 -> [-2, -4] + 3 -> [1, -1]
                        // 2 [1, 2] -> [2, 4] -> [-1, 1]
                        const shift = 2 * @as(i8, @intCast(key.scan_code)) - 3;

                        self._highlighted = if (self._highlighted == 0 and shift < 0)
                            self.entries.len - @as(u8, @intCast(-shift))
                        else
                            @as(usize, @intCast((@as(isize, @intCast(self._highlighted)) + shift))) % self.entries.len;
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

        pub fn draw(self: *const Self) !void {
            // Clear our screen
            try self.out.reset(false);

            var center = Vec{ .x = @divFloor(self._res.x, 2), .y = @divFloor(self._res.y, 2) };

            center.y -= @divFloor(self.entries.len, 2);

            for (self.entries, 0..) |entry, i| {
                const start = center.x - @divFloor(entry.description.len, 2);

                try self.out.setCursorPosition(start, center.y + i);

                if (self._highlighted == i) {
                    _ = self.out.con.setAttribute(ConOut.background_lightgray | ConOut.black);
                } else {
                    _ = self.out.con.setAttribute(ConOut.background_black | ConOut.white);
                }

                try self.out.print16(entry.description);
                try self.out.print("\r\n");
            }

            _ = self.out.con.setAttribute(ConOut.background_black | ConOut.white);
            try self.out.println("");
        }
    };
}
