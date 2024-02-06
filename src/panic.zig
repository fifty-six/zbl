const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const Status = uefi.Status;

const SimpleTextOutputProtocol = uefi.protocol.SimpleTextOutput;

const Output = @import("Output.zig");

var already_panicking: bool = false;

// For adding debug info later.
var panic_allocator_bytes: [100 * 1024]u8 = undefined;
var panic_allocator_state = std.heap.FixedBufferAllocator.init(&panic_allocator_bytes);
const panic_allocator = panic_allocator_state.allocator();

pub fn die(status: Status) noreturn {
    uefi.system_table.runtime_services.resetSystem(.ResetShutdown, status, 0, null);
}

const Reset = enum { Clear, Unchanged };

pub fn print_to(out: Output, msg: []const u8, reset: Reset) void {
    _ = out.con.setAttribute(SimpleTextOutputProtocol.red);

    if (reset == .Clear) {
        out.reset(false) catch {};
    }

    out.printf("\r\nerr: {s}\r\n", .{msg}) catch {};
    out.println("Press any key to stop.") catch {};
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    // Don't have DWARF info.
    _ = error_return_trace;

    const stdout = Output{ .con = uefi.system_table.con_out.? };

    if (already_panicking) {
        // Eat the error this time if there is one, doesn't matter.
        stdout.println("Panicked during panic!") catch {};
        // stderr.println("Panicked during panic!") catch {};

        asm volatile ("hlt");

        while (true) {}
    }

    if (uefi.system_table.std_err) |stderr| {
        print_to(Output{ .con = stderr }, msg, .Clear);
    }
    print_to(stdout, msg, .Clear);

    const input_events = [_]uefi.Event{uefi.system_table.con_in.?.wait_for_key};

    var index: usize = undefined;

    // Make sure we have at least 3 seconds to see the error
    // to prevent accidental dismissal of the message.
    _ = uefi.system_table.boot_services.?.stall(3 * 1000 * 1000);

    // Wait for an input.
    if (uefi.system_table.boot_services.?.waitForEvent(input_events.len, &input_events, &index) == .Success) {
        die(.Aborted);
    }

    // Try to halt instead of busy-looping.
    asm volatile ("hlt");

    // Oh well.
    while (true) {}
}
