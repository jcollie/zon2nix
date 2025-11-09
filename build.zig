const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig = b.option([]const u8, "zig", "Path to zig") orelse "zig";
    const nix_prefetch_git = b.option([]const u8, "nix-prefetch-git", "Path to nix-prefetch-git") orelse "nix-prefetch-git";
    const nixfmt = b.option([]const u8, "nixfmt", "Path to nixfmt") orelse "nixfmt";

    const options = b.addOptions();
    options.addOption([]const u8, "zig", zig);
    options.addOption([]const u8, "nix_prefetch_git", nix_prefetch_git);
    options.addOption([]const u8, "nixfmt", nixfmt);

    const root_mod = b.addModule(
        "zon2nix",
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    const main_mod = b.createModule(
        .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit tests");
    const test_valgrind_step = b.step("test-valgrind", "Run tests under valgrind");
    const run_valgrind_step = b.step("run-valgrind", "Run executable under valgrind");

    {
        const exe = b.addExecutable(.{
            .name = "zon2nix",
            .root_module = main_mod,
        });
        exe.root_module.addImport("zon2nix", root_mod);
        exe.root_module.addOptions("options", options);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    }

    {
        const root_exe = b.addTest(.{
            .root_module = root_mod,
        });
        const run_root_cmd = b.addRunArtifact(root_exe);

        const main_exe = b.addTest(.{
            .root_module = root_mod,
        });
        const run_main_cmd = b.addRunArtifact(main_exe);
        test_step.dependOn(&run_root_cmd.step);
        test_step.dependOn(&run_main_cmd.step);
    }

    {
        const mod = b.createModule(
            .{
                .root_source_file = b.path("src/root.zig"),
                .target = baseline(target),
                .optimize = optimize,
            },
        );
        const exe = b.addTest(.{
            .root_module = mod,
        });

        const run = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--num-callers=50",
            "--gen-suppressions=all",
        });
        run.addArtifactArg(exe);
        test_valgrind_step.dependOn(&run.step);
    }

    {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = baseline(target),
            .optimize = optimize,
        });
        const exe = b.addExecutable(.{
            .name = "zon2nix",
            .root_module = mod,
        });
        exe.root_module.addImport("zon2nix", root_mod);
        exe.root_module.addOptions("options", options);
        const run_cmd = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--num-callers=50",
            "--gen-suppressions=all",
        });
        run_cmd.addArtifactArg(exe);
        if (b.args) |args| run_cmd.addArgs(args);

        run_valgrind_step.dependOn(&run_cmd.step);
    }
}

fn baseline(target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    var query = target.query;
    query.cpu_model = .baseline;

    return .{
        .query = query,
        .result = std.zig.system.resolveTargetQuery(query) catch @panic("unable to resolve baseline query"),
    };
}
