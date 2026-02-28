const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SQLite C 静态库
    const sqlite_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_mod.addCSourceFile(.{
        .file = b.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
        },
    });
    const sqlite = b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite3",
        .root_module = sqlite_mod,
    });

    // 主程序
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addIncludePath(b.path("."));
    exe_mod.linkLibrary(sqlite);
    const exe = b.addExecutable(.{
        .name = "jfai",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // 运行命令
    const run_step = b.step("run", "运行 jfai 服务");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // 测试
    const test_sources = [_][]const u8{
        "src/config.zig",
        "src/id.zig",
        "src/storage.zig",
        "src/rate_limiter.zig",
        "src/handler.zig",
        "src/router.zig",
        "src/cleaner.zig",
    };

    const test_step = b.step("test", "运行所有测试");
    for (test_sources) |src| {
        const t_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        t_mod.addIncludePath(b.path("."));
        t_mod.linkLibrary(sqlite);
        const t = b.addTest(.{ .root_module = t_mod });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
