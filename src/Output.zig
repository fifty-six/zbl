const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const Status = uefi.Status;

const SimpleTextOutputProtocol = uefi.protocols.SimpleTextOutputProtocol;

const Self = @This();

con: *SimpleTextOutputProtocol,

pub fn putchar(self: *const Self, char: u16) !void {
    var buf = [_]u16{ char, 0 };
    try err(self.con.outputString(@ptrCast([*:0]u16, &buf)));
}

pub fn print16(self: *const Self, buf: [*:0]const u16) !void {
    try err(self.con.outputString(buf));
}

pub fn print(self: *const Self, comptime buf: []const u8) !void {
    try err(self.con.outputString(std.unicode.utf8ToUtf16LeStringLiteral(buf)));
}

pub fn printf(self: *const Self, comptime format: []const u8, args: anytype) !void {
    var utf16: [256:0]u16 = undefined;
    var format_buf: [256]u8 = undefined;

    var slice = try std.fmt.bufPrint(&format_buf, format, args);
    var length = try std.unicode.utf8ToUtf16Le(&utf16, slice);

    utf16[length] = 0;

    try err(self.con.outputString(&utf16));
}

pub fn println(self: *const Self, comptime buf: []const u8) !void {
    try self.print(buf ++ "\r\n");
}

pub fn reset(self: *const Self, verify: bool) !void {
    try err(self.con.reset(verify));
}

pub fn setCursorPosition(self: *const Self, column: usize, row: usize) !void {
    try err(self.con.setCursorPosition(column, row));
}

fn err(status: Status) !void {
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
