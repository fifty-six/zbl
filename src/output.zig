const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const Status = uefi.Status;

const SimpleTextOutputProtocol = uefi.protocols.SimpleTextOutputProtocol;

pub const Output = struct {
    con: *SimpleTextOutputProtocol,

    pub fn putchar(self: *const Output, char: u16) !void {
        var buf = [_]u16{ char, 0 };
        try self.err(self.con.outputString(@ptrCast([*:0]u16, &buf)));
    }

    pub fn print16(self: *const Output, buf: [*:0]const u16) !void {
        try self.err(self.con.outputString(buf));
    }

    pub fn print(self: *const Output, comptime buf: []const u8) !void {
        try self.err(self.con.outputString(std.unicode.utf8ToUtf16LeStringLiteral(buf)));
    }

    pub fn printf(self: *const Output, comptime format: []const u8, args: anytype) !void {
        var utf16: [256:0]u16 = undefined;
        var format_buf: [256]u8 = undefined;

        var slice = try std.fmt.bufPrint(&format_buf, format, args);
        var length = try std.unicode.utf8ToUtf16Le(&utf16, slice);

        utf16[length] = 0;

        try self.err(self.con.outputString(&utf16));
    }

    pub fn println(self: *const Output, comptime buf: []const u8) !void {
        try self.print(buf ++ "\r\n");
    }

    pub fn reset(self: *const Output, verify: bool) !void {
        try self.err(self.con.reset(verify));
    }

    pub fn setCursorPosition(self: *const Output, column: usize, row: usize) !void {
        try self.err(self.con.setCursorPosition(column, row));
    }

    fn err(self: *const Output, status: Status) !void {
        if (status != .Success) {
            return switch (status) {
                .DeviceError => error.DeviceError,
                .Unsupported => error.Unsupported,
                // A bit overkill, but we deal with it early.
                .WarnUnknownGlyph => error.UnknownGlyph,
                else => unreachable,
            };
        }
    }
};
