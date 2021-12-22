const std = @import("std");
const uefi = std.os.uefi;

const protocols = uefi.protocols;
const Status = uefi.Status;

const menus = @import("menu.zig");
const output = @import("output.zig");
const move = @import("move.zig");
const text = @import("text.zig");
const device_path = @import("device_path.zig");
const uefi_alloc = @import("uefi_allocator.zig");

const Output = output.Output;

const Menu = menus.Menu;
const MenuEntry = menus.MenuEntry;

const utf16_str = std.unicode.utf8ToUtf16LeStringLiteral;

var alloc_bytes: [100 * 1024]u8 = undefined;
var alloc_state = std.heap.FixedBufferAllocator.init(&alloc_bytes);
const fixed_alloc = alloc_state.allocator();

var sys_table: *uefi.tables.SystemTable = undefined;
var boot_services: *uefi.tables.BootServices = undefined;
var con_in: *protocols.SimpleTextInputProtocol = undefined;
var con_out: *protocols.SimpleTextOutputProtocol = undefined;
var out: Output = undefined;

pub fn open_protocol(handle: uefi.Handle, comptime protocol: type) !*protocol {
    var ptr: *protocol = undefined;
    if (boot_services.openProtocol(
        handle,
        &protocol.guid,
        @ptrCast(*?*anyopaque, &ptr),
        uefi.handle,
        null,
        uefi.tables.OpenProtocolAttributes{ .by_handle_protocol = true },
    ) != .Success) {
        return error.FailedToOpenProtocol;
    }

    return ptr;
}

pub const Loader = struct {
    const Self = @This();

    disk: *protocols.DevicePathProtocol,
    file_handle: *const protocols.FileProtocol,

    disk_name: [:0]const u16,
    file_name: [:0]const u16,
};

pub fn scan_dir(
    alloc: std.mem.Allocator,
    li: *std.ArrayList(Loader),
    fp: *const protocols.FileProtocol,
    dp: *protocols.DevicePathProtocol,
    disk_name: [:0]const u16,
) !void {
    var buf: [1024]u8 align(8) = undefined;
    var size = buf.len;

    while (true) {
        size = buf.len;

        switch (fp.read(&size, &buf)) {
            .Success => {},
            .BufferTooSmall => return error.BufferTooSmall,
            else => return error.DiskError,
        }

        if (size == 0)
            break;

        // const efi_file_dir = protocols.FileInfo.efi_file_directory;

        var file_info = @ptrCast(*protocols.FileInfo, &buf);

        var fname = std.mem.span(file_info.getFileName());

        if (std.mem.endsWith(u16, fname, utf16_str(".efi")) or std.mem.endsWith(u16, fname, utf16_str(".EFI"))) {
            var loader_handle: *const protocols.FileProtocol = undefined;

            if (fp.open(
                &loader_handle,
                file_info.getFileName(),
                protocols.FileProtocol.efi_file_mode_read,
                undefined,
            ) != .Success) {
                return error.LoaderHandleError;
            }

            var name: []u16 = try alloc.alloc(u16, fname.len + 1);
            name[name.len - 1] = 0;

            std.mem.copy(u16, name, fname);

            try li.append(Loader{
                .disk = dp,
                .file_handle = loader_handle,
                .file_name = name[0 .. name.len - 1 :0],
                .disk_name = disk_name,
            });

            // try out.print("Found loader! ");
            // try out.print16(fname);
            // try out.println("");
        }

        // try out.println("\r\n");
        // try out.printf("read size {d}\r\n", .{size});
        // try out.print16(file_info.getFileName());
        // try out.printf("\r\nstruct size: {d} fileSize: {d}, physicalSize: {d}, attr: {x}, dir: {x} \r\n", .{
        //     file_info.size,
        //     file_info.file_size,
        //     file_info.physical_size,
        //     file_info.attribute,
        //     (file_info.attribute & efi_file_dir) == efi_file_dir,
        // });
        // try out.println("\r\n");

        // _ = boot_services.stall(5 * 1000 * 100);
    }
}

pub fn main() void {
    caught_main() catch unreachable;
}

pub fn caught_main() !void {
    sys_table = uefi.system_table;
    boot_services = sys_table.boot_services.?;
    con_out = sys_table.con_out.?;
    con_in = sys_table.con_in.?;
    out = Output{ .con = con_out };

    try out.reset(false);

    const image = uefi.handle;

    var img_proto = try open_protocol(image, protocols.LoadedImageProtocol);

    var handle_ptr: [*]uefi.Handle = undefined;
    var res_size: usize = undefined;

    if (boot_services.locateHandleBuffer(
        .ByProtocol,
        &protocols.SimpleFileSystemProtocol.guid,
        null,
        &res_size,
        &handle_ptr,
    ) != .Success) {
        return error.EnumerateHandleFailure;
    }

    var heap_alloc_state = std.heap.ArenaAllocator.init(uefi_alloc.allocator);
    var heap_alloc = heap_alloc_state.allocator();

    var handles = handle_ptr[0..res_size];

    var loaders = std.ArrayList(Loader).init(heap_alloc);

    for (handles) |handle| {
        var sfsp = try open_protocol(handle, protocols.SimpleFileSystemProtocol);
        var path = try open_protocol(handle, protocols.DevicePathProtocol);

        var fp: *const protocols.FileProtocol = undefined;

        if (sfsp.openVolume(&fp) != .Success)
            return error.UnableToOpenVolume;

        var str_path = try device_path.to_str(heap_alloc, path);

        try scan_dir(heap_alloc, &loaders, fp, path, str_path);
    }

    try out.print16(try device_path.to_str(fixed_alloc, img_proto.file_path));
    try out.print("\r\n");

    for (loaders.items) |entry| {
        try out.print16(entry.disk_name);
        try out.print(": ");
        try out.print16(entry.file_name);
        try out.println("");
    }

    _ = boot_services.stall(3 * 1000 * 1000);

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
