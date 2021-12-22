const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const Status = uefi.Status;

const SimpleTextOutputProtocol = uefi.protocols.SimpleTextOutputProtocol;

const Output = @import("output.zig").Output;

var already_panicking: bool = false;

// For adding debug info later.
var panic_allocator_bytes: [100 * 1024]u8 = undefined;
var panic_allocator_state = std.heap.FixedBufferAllocator.init(&panic_allocator_bytes);
const panic_allocator = panic_allocator_state.allocator();

pub fn die(status: Status) noreturn {
    uefi.system_table.runtime_services.resetSystem(.ResetShutdown, status, 0, null);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    @setCold(true);

    // Don't have DWARF info.
    _ = error_return_trace;

    const out = Output{ .con = uefi.system_table.std_err.? };

    if (already_panicking) {
        // Eat the error this time if there is one, doesn't matter.
        out.println("Panicked during panic!") catch {};

        asm volatile ("hlt");

        while (true) {}
    }

    _ = out.con.setAttribute(SimpleTextOutputProtocol.red);

    out.reset(false) catch unreachable;

    out.printf("\r\nerr: {s}\r\n", .{msg}) catch unreachable;
    out.println("Press any key to stop.") catch unreachable;

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
