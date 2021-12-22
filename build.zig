const std = @import("std");

const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("bootx64", "src/main.zig");
    exe.setTarget(CrossTarget{ .cpu_arch = Target.Cpu.Arch.x86_64, .os_tag = Target.Os.Tag.uefi, .abi = Target.Abi.msvc });

    exe.setBuildMode(mode);
    exe.setOutputDir("EFI/Boot");
    exe.install();

    b.default_step.dependOn(&exe.step);

    const qemu = b.step("qemu", "runs boot");

    const run_qemu = b.addSystemCommand(&[_][]const u8{ "zsh", "./run" });

    run_qemu.step.dependOn(&exe.step);
    qemu.dependOn(&run_qemu.step);
}
