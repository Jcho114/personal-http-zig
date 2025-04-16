const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http_module = b.createModule(.{
        .root_source_file = b.path("lib/http.zig"),
        .target = target,
        .optimize = optimize,
    });

    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_exe.root_module.addImport("http", http_module);
    b.installArtifact(server_exe);
    const server_run_cmd = b.addRunArtifact(server_exe);
    server_run_cmd.step.dependOn(b.getInstallStep());
    const server_run_step = b.step("server", "src/server.zig");
    server_run_step.dependOn(&server_run_cmd.step);

    const test_step = b.step("test", "Run all tests");
    const test_files = [_][]const u8{
        "lib/radix.zig",
        "lib/json.zig",
    };
    for (test_files) |test_file| {
        const test_artifact = b.addTest(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        test_artifact.root_module.addImport("http", http_module);

        const run_test = b.addRunArtifact(test_artifact);
        test_step.dependOn(&run_test.step);
    }
}
