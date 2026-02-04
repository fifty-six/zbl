const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const Status = uefi.Status;

const SimpleTextOutputProtocol = uefi.protocol.SimpleTextOutput;

const Self = @This();

con: *SimpleTextOutputProtocol,

// TODO for these, maybe warn on unknown char? or print ?
pub fn putchar(self: *const Self, char: u16) !void {
    var buf = [_]u16{ char, 0 };
    _ = try self.con.outputString(@as([*:0]u16, @ptrCast(&buf)));
}

pub fn print16(self: *const Self, buf: [*:0]const u16) !void {
    _ = try self.con.outputString(buf);
}

pub fn print(self: *const Self, comptime buf: []const u8) !void {
    _ = try self.con.outputString(std.unicode.utf8ToUtf16LeStringLiteral(buf));
}

pub fn printf(self: *const Self, comptime format: []const u8, args: anytype) !void {
    var utf16: [2048:0]u16 = undefined;
    var format_buf: [2048]u8 = undefined;

    const slice = try std.fmt.bufPrint(&format_buf, format, args);
    const length = try std.unicode.utf8ToUtf16Le(&utf16, slice);

    utf16[length] = 0;

    _ = try self.con.outputString(&utf16);
}

pub fn print16ln(self: *const Self, buf: [*:0]const u16) !void {
    try self.print16(buf);
    try self.print("\r\n");
}

pub fn println(self: *const Self, comptime buf: []const u8) !void {
    try self.print(buf ++ "\r\n");
}

pub fn reset(self: *const Self, verify: bool) !void {
    try self.con.reset(verify);
}

pub fn setCursorPosition(self: *const Self, column: usize, row: usize) !void {
    try self.con.setCursorPosition(column, row);
}

// fn err(status: Status) !void {
//     if (status != .Success) {
//         return switch (status) {
//             .DeviceError => error.DeviceError,
//             .Unsupported => error.Unsupported,
//             // A bit overkill, but we deal with it early.
//             .WarnUnknownGlyph => error.UnknownGlyph,
//             // e.g. ASROCK gives us NotFound for [U+E8D7, ...]
//             else => return error.UnexpectedStatus,
//         };
//     }
// }
