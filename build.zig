const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fuzz_iterations = b.option(u64, "fuzz-iterations", "Number of fuzz cases in the round-trip test (default 300)") orelse 300;
    const fuzz_seed = b.option(u64, "fuzz-seed", "First fuzz seed in the round-trip test (default 1)") orelse 1;

    const ghostty = b.lazyDependency("ghostty", .{}) orelse return;
    const ghostty_vt = ghostty.module("ghostty-vt");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("ghostty-vt", ghostty_vt);

    const exe = b.addExecutable(.{
        .name = "granite",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run granite").dependOn(&run_cmd.step);

    const recording_mod = b.createModule(.{
        .root_source_file = b.path("src/recording.zig"),
        .target = target,
        .optimize = optimize,
    });

    const record = b.addExecutable(.{
        .name = "granite-record",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/record.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "recording", .module = recording_mod }},
        }),
    });
    b.installArtifact(record);

    // Tests
    const mux_mod = b.createModule(.{
        .root_source_file = b.path("src/mux.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ghostty-vt", .module = ghostty_vt }},
    });

    const roundtrip_options = b.addOptions();
    roundtrip_options.addOption(u64, "fuzz_iterations", fuzz_iterations);
    roundtrip_options.addOption(u64, "fuzz_seed", fuzz_seed);
    roundtrip_options.addOptionPathDirectory("recordings_dir", b.path("test/recordings"));

    // The round-trip test renders a frame per byte for some splits, which
    // is too slow in Debug.
    const test_optimize: @TypeOf(optimize) = if (optimize == .debug) .safe else optimize;

    const roundtrip = b.addTest(.{
        .name = "roundtrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/roundtrip.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ghostty-vt", .module = ghostty_vt },
                .{ .name = "mux", .module = mux_mod },
                .{ .name = "recording", .module = recording_mod },
                .{ .name = "test_options", .module = roundtrip_options.createModule() },
            },
        }),
    });

    const child = b.addExecutable(.{
        .name = "granite-test-child",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/child.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const live_options = b.addOptions();
    live_options.addOptionPath("granite", exe.getEmittedBin());
    live_options.addOptionPath("child", child.getEmittedBin());

    const live = b.addTest(.{
        .name = "live",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/live.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ghostty-vt", .module = ghostty_vt },
                .{ .name = "mux", .module = mux_mod },
                .{ .name = "live_options", .module = live_options.createModule() },
            },
        }),
    });

    const test_step = b.step("test", "Run the round-trip and live tests");
    test_step.dependOn(&b.addRunArtifact(roundtrip).step);
    test_step.dependOn(&b.addRunArtifact(live).step);
}
