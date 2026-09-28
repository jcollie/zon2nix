// SPDX-FileCopyrightText: 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
//
// SPDX-License-Identifier: MIT

//! Unpacking a package archive and computing its Zig package hash, the way
//! `zig fetch` does, without running it.
//!
//! `zig fetch` does two things zon2nix needs -- it unpacks the package, so
//! that its own `build.zig.zon` can be read, and it proves that the package
//! matches the hash the manifest names -- and one it does not: it recompresses
//! the unpacked tree into a gzip tarball at level 9 for its global cache. That
//! last step is nearly all of its time. gettext's 27 MB tarball takes eight
//! seconds of one core through `zig fetch`, and under half a second through
//! this.
//!
//! This is a port of what Zig 0.16.0's `src/Package/Fetch.zig` and
//! `src/Package.zig` do for an archive, and it has to agree with them bit for
//! bit, since a hash that differs is reported as a mismatch. The archive is
//! unpacked with the same `std.tar` and `std.zip` calls and options, so the
//! tree on disk is the one Zig would see; the manifest's `paths` decide which
//! files belong to the package; and the hash is taken over those files the
//! same way. Git dependencies are not handled here and still go through
//! `zig fetch`.

const std = @import("std");
const Io = std.Io;

const BuildZigZon = @import("BuildZigZon.zig");

const log = std.log.scoped(.package);

const Sha256 = std.crypto.hash.sha2.Sha256;

/// What `unpack` leaves behind.
pub const Unpacked = struct {
    /// The absolute path of the package's root directory: where its
    /// `build.zig.zon` is, if it has one.
    root: []const u8,
    /// The package hash, in the form a manifest names it:
    /// `name-version-hashplus`.
    hash: []const u8,

    pub fn deinit(self: Unpacked, alloc: std.mem.Allocator) void {
        alloc.free(self.root);
        alloc.free(self.hash);
    }
};

/// Unpacks the archive at `archive_path` into `dest`, an empty directory
/// whose absolute path is `dest_path`, and computes its package hash.
///
/// Files the manifest's `paths` leave out are deleted from the tree
/// afterwards, as Zig does, so what remains is the package as Zig would
/// build it.
pub fn unpack(
    io: Io,
    alloc: std.mem.Allocator,
    archive_path: []const u8,
    dest: Io.Dir,
    dest_path: []const u8,
) !Unpacked {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var archive = try Io.Dir.cwd().openFile(io, archive_path, .{});
    defer archive.close(io);

    const file_type = try FileType.detect(archive_path);

    const read_buffer = try arena.alloc(u8, 64 * 1024);
    var archive_reader = archive.reader(io, read_buffer);

    const unpacked = try unpackArchive(io, alloc, arena, file_type, &archive_reader, dest);

    const root_rel = unpacked.root_dir;
    var root_dir = try dest.openDir(io, if (root_rel.len == 0) "." else root_rel, .{ .iterate = true });
    defer root_dir.close(io);

    var manifest = try loadManifest(io, alloc, arena, root_dir);
    defer if (manifest) |*m| m.deinit();

    var filter: Filter = .{};
    if (manifest) |m| {
        for (m.paths.items) |path| {
            // Normalized the way the compiler's manifest parser does, so that
            // `./src/` and `src` name the same directory.
            try filter.include_paths.put(arena, try std.fs.path.resolve(arena, &.{path}), {});
        }
    }

    // Unpacking errors -- a symlink that could not be made, a file of a type
    // tar can hold and a package cannot -- only matter for files the package
    // actually includes.
    var failed = false;
    for (unpacked.errors) |item| {
        const name = stripRoot(item.file_name, root_rel);
        if (!filter.includePath(name)) continue;
        log.err("{s}: {s}", .{ name, item.message });
        failed = true;
    }
    if (failed) return error.UnpackFailed;

    const computed = try computeHash(io, arena, root_dir, &filter);

    const hash = if (manifest) |m| hash: {
        const name = m.name orelse return missingField(archive_path, "name");
        const version_text = m.version orelse return missingField(archive_path, "version");
        const fingerprint = m.fingerprint orelse return missingField(archive_path, "fingerprint");
        // Parsed and printed again rather than used as written, which is what
        // Zig does, and what makes the version in the hash canonical.
        const version = std.SemanticVersion.parse(version_text) catch {
            log.err("{s}: unable to parse version '{s}'", .{ archive_path, version_text });
            return error.InvalidManifest;
        };
        var version_buffer: [max_field_len]u8 = undefined;
        const canonical = std.fmt.bufPrint(&version_buffer, "{f}", .{version}) catch {
            log.err("{s}: version '{s}' is longer than {d} bytes", .{ archive_path, version_text, max_field_len });
            return error.InvalidManifest;
        };
        if (name.len > max_field_len) {
            log.err("{s}: name '{s}' is longer than {d} bytes", .{ archive_path, name, max_field_len });
            return error.InvalidManifest;
        }
        // The fingerprint's low half is the package id; the high half is a
        // checksum of the name, which Zig checks and the hash does not use.
        break :hash try formatHash(alloc, computed, name, canonical, @truncate(fingerprint));
    } else
        // A package without a manifest is "naked", and Zig names it with
        // placeholders.
        try formatHash(alloc, computed, "N", "V", 0xffff);
    errdefer alloc.free(hash);

    const root = try std.fs.path.join(alloc, &.{ dest_path, root_rel });
    return .{ .root = root, .hash = hash };
}

fn missingField(archive_path: []const u8, field: []const u8) error{InvalidManifest} {
    log.err("{s}: build.zig.zon has no '{s}' field", .{ archive_path, field });
    return error.InvalidManifest;
}

fn loadManifest(io: Io, alloc: std.mem.Allocator, arena: std.mem.Allocator, root_dir: Io.Dir) !?BuildZigZon {
    var file = root_dir.openFile(io, "build.zig.zon", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer file.close(io);
    const buffer = try arena.alloc(u8, 4096);
    var reader = file.reader(io, buffer);
    return try BuildZigZon.init(alloc, &reader.interface, "build.zig.zon");
}

/// The longest name, and the longest version, a package hash can hold.
const max_field_len = 32;

/// The file types Zig can unpack a package from.
const FileType = enum {
    tar,
    @"tar.gz",
    @"tar.xz",
    @"tar.zst",
    zip,

    /// By name, the way `zig fetch` decides for a local file.
    ///
    /// The contents could say, but the generated Nix expression cannot use
    /// them: `fetchzip` and `zig fetch` both go by the name too, so a URL
    /// with no extension would produce an expression that fails to build.
    /// It is refused here instead, where the reason can be given.
    fn detect(path: []const u8) !FileType {
        return fromPath(path) orelse {
            log.err("{s}: the URL does not end in an archive extension (.tar.gz, .tgz, .tar.xz, .txz, .tar.zst, .tzst, .tar, .zip, .jar)", .{std.fs.path.basename(path)});
            log.err("the Nix expression zon2nix writes decides how to unpack a package by its extension, and could not unpack this one", .{});
            return error.UnknownFileType;
        };
    }

    fn fromPath(path: []const u8) ?FileType {
        const ascii = std.ascii;
        if (ascii.endsWithIgnoreCase(path, ".tar")) return .tar;
        if (ascii.endsWithIgnoreCase(path, ".tgz")) return .@"tar.gz";
        if (ascii.endsWithIgnoreCase(path, ".tar.gz")) return .@"tar.gz";
        if (ascii.endsWithIgnoreCase(path, ".txz")) return .@"tar.xz";
        if (ascii.endsWithIgnoreCase(path, ".tar.xz")) return .@"tar.xz";
        if (ascii.endsWithIgnoreCase(path, ".tzst")) return .@"tar.zst";
        if (ascii.endsWithIgnoreCase(path, ".tar.zst")) return .@"tar.zst";
        if (ascii.endsWithIgnoreCase(path, ".zip")) return .zip;
        if (ascii.endsWithIgnoreCase(path, ".jar")) return .zip;
        return null;
    }
};

const UnpackError = struct {
    file_name: []const u8,
    message: []const u8,
};

const ArchiveResult = struct {
    /// The single directory everything in the archive was inside, or empty
    /// if there was none. This is what Zig strips.
    root_dir: []const u8,
    errors: []const UnpackError,
};

fn unpackArchive(
    io: Io,
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    file_type: FileType,
    archive_reader: *Io.File.Reader,
    dest: Io.Dir,
) !ArchiveResult {
    switch (file_type) {
        .tar => return unpackTarball(io, arena, &archive_reader.interface, dest),
        .@"tar.gz" => {
            const window = try arena.alloc(u8, std.compress.flate.max_window_len);
            var decompress: std.compress.flate.Decompress = .init(&archive_reader.interface, .gzip, window);
            return unpackTarball(io, arena, &decompress.reader, dest);
        },
        .@"tar.xz" => {
            var decompress = try std.compress.xz.Decompress.init(&archive_reader.interface, alloc, &.{});
            defer decompress.deinit();
            return unpackTarball(io, arena, &decompress.reader, dest);
        },
        .@"tar.zst" => {
            const window_len = std.compress.zstd.default_window_len;
            const window = try arena.alloc(u8, window_len + std.compress.zstd.block_size_max);
            var decompress: std.compress.zstd.Decompress = .init(&archive_reader.interface, window, .{
                .verify_checksum = false,
                .window_len = window_len,
            });
            return unpackTarball(io, arena, &decompress.reader, dest);
        },
        .zip => {
            // Zip is read from the end, which the file on disk allows directly;
            // `zig fetch` copies a download to a temporary file for this.
            var diagnostics: std.zip.Diagnostics = .{ .allocator = arena };
            try std.zip.extract(dest, archive_reader, .{
                .allow_backslashes = true,
                .diagnostics = &diagnostics,
            });
            return .{ .root_dir = diagnostics.root_dir, .errors = &.{} };
        },
    }
}

fn unpackTarball(io: Io, arena: std.mem.Allocator, reader: *Io.Reader, dest: Io.Dir) !ArchiveResult {
    var diagnostics: std.tar.Diagnostics = .{ .allocator = arena };

    // The options are the ones `zig fetch` uses, which is what makes the tree
    // -- and so the hash -- the same.
    try std.tar.extract(io, dest, reader, .{
        .diagnostics = &diagnostics,
        .strip_components = 0,
        .mode_mode = .ignore,
        .exclude_empty_directories = true,
    });

    const errors = try arena.alloc(UnpackError, diagnostics.errors.items.len);
    for (diagnostics.errors.items, errors) |item, *out| {
        out.* = switch (item) {
            .unable_to_create_file => |i| .{
                .file_name = i.file_name,
                .message = try std.fmt.allocPrint(arena, "unable to create file: {t}", .{i.code}),
            },
            .unable_to_create_sym_link => |i| .{
                .file_name = i.file_name,
                .message = try std.fmt.allocPrint(arena, "unable to create symlink to '{s}': {t}", .{ i.link_name, i.code }),
            },
            .unsupported_file_type => |i| .{
                .file_name = i.file_name,
                .message = try std.fmt.allocPrint(arena, "unsupported file type '{c}'", .{@intFromEnum(i.file_type)}),
            },
            // Only possible with `strip_components` above zero.
            .components_outside_stripped_prefix => unreachable,
        };
    }
    return .{ .root_dir = diagnostics.root_dir, .errors = errors };
}

/// Which files belong to a package, from its manifest's `paths`: a file is in
/// if it, or any directory above it, is named there. No `paths` at all, or
/// one naming the root, takes everything.
const Filter = struct {
    include_paths: std.StringArrayHashMapUnmanaged(void) = .empty,

    fn includePath(self: *const Filter, sub_path: []const u8) bool {
        if (self.include_paths.count() == 0) return true;
        if (self.include_paths.contains("")) return true;
        if (self.include_paths.contains(".")) return true;
        if (self.include_paths.contains(sub_path)) return true;

        var dirname = sub_path;
        while (std.fs.path.dirname(dirname)) |next_dirname| {
            if (self.include_paths.contains(next_dirname)) return true;
            dirname = next_dirname;
        }
        return false;
    }
};

/// Strips the archive's root directory from a path as the archive named it.
fn stripRoot(path: []const u8, root_dir: []const u8) []const u8 {
    if (root_dir.len == 0 or path.len <= root_dir.len) return path;
    if (std.mem.eql(u8, path[0..root_dir.len], root_dir) and std.fs.path.isSep(path[root_dir.len])) {
        return path[root_dir.len + 1 ..];
    }
    return path;
}

const ComputedHash = struct {
    digest: [Sha256.digest_length]u8,
    /// Bytes of file content in the package. Symlinks count for nothing.
    total_size: u64,
};

const HashedFile = struct {
    path: []const u8,
    digest: [Sha256.digest_length]u8,

    fn lessThan(_: void, lhs: HashedFile, rhs: HashedFile) bool {
        return std.mem.lessThan(u8, lhs.path, rhs.path);
    }
};

/// Hashes every file under `root_dir` the filter includes, and deletes the
/// ones it does not, along with any directory that leaves empty.
///
/// Each file is hashed on its own -- its path, two zero bytes standing for an
/// executable bit Zig always treats as clear, then its contents; or, for a
/// symlink, its path and its target -- and the package digest is the hash of
/// those digests in order of path. Directories are not hashed at all.
fn computeHash(io: Io, arena: std.mem.Allocator, root_dir: Io.Dir, filter: *const Filter) !ComputedHash {
    var files: std.ArrayList(HashedFile) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    var total_size: u64 = 0;

    const buffer = try arena.alloc(u8, 64 * 1024);

    var walker = try root_dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;

        // Zig hashes the path with `/` as the separator whatever the
        // platform, which on the platforms zon2nix runs on it already is.
        const path = try arena.dupe(u8, entry.path);

        if (!filter.includePath(path)) {
            try excluded.append(arena, path);
            continue;
        }

        var hasher: Sha256 = .init(.{});
        hasher.update(path);

        switch (entry.kind) {
            .file => {
                hasher.update(&.{ 0, 0 });
                var file = try entry.dir.openFile(io, entry.basename, .{});
                defer file.close(io);
                var offset: u64 = 0;
                while (true) {
                    const len = try file.readPositional(io, &.{buffer}, offset);
                    if (len == 0) break;
                    hasher.update(buffer[0..len]);
                    offset += len;
                }
                total_size += offset;
            },
            .sym_link => {
                const len = try entry.dir.readLink(io, entry.basename, buffer);
                hasher.update(buffer[0..len]);
            },
            else => {
                log.err("{s} has type '{t}', which a package cannot contain", .{ path, entry.kind });
                return error.IllegalFileType;
            },
        }

        try files.append(arena, .{ .path = path, .digest = hasher.finalResult() });
    }

    try removeExcluded(io, arena, root_dir, excluded.items);

    std.mem.sortUnstable(HashedFile, files.items, {}, HashedFile.lessThan);

    var hasher: Sha256 = .init(.{});
    for (files.items) |file| hasher.update(&file.digest);

    return .{ .digest = hasher.finalResult(), .total_size = total_size };
}

/// Deletes the files a package's `paths` leave out, and then every directory
/// that has become empty, deepest first.
fn removeExcluded(io: Io, arena: std.mem.Allocator, root_dir: Io.Dir, excluded: []const []const u8) !void {
    var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;

    for (excluded) |path| {
        try root_dir.deleteFile(io, path);
        if (std.fs.path.dirname(path)) |parent| try dirs.put(arena, parent, {});
    }

    const ByLengthDescending = struct {
        keys: []const []const u8,
        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.keys[b].len < ctx.keys[a].len;
        }
    };
    dirs.sortUnstable(ByLengthDescending{ .keys = dirs.keys() });

    // Removing a directory can empty its parent, which is added as it goes,
    // so this walks by index rather than by iterator.
    var i: usize = 0;
    while (i < dirs.count()) : (i += 1) {
        const dir = dirs.keys()[i];
        root_dir.deleteDir(io, dir) catch |err| switch (err) {
            error.DirNotEmpty, error.FileNotFound => continue,
            else => |e| return e,
        };
        if (std.fs.path.dirname(dir)) |parent| try dirs.put(arena, parent, {});
    }
}

/// Formats a package hash: `name-version-` and then 33 bytes in URL-safe
/// base64 -- the package id and the total size, each a little-endian `u32`
/// with the size saturating, and the first 25 bytes of the digest.
fn formatHash(
    alloc: std.mem.Allocator,
    computed: ComputedHash,
    name: []const u8,
    version: []const u8,
    id: u32,
) ![]const u8 {
    var hashplus: [33]u8 = undefined;
    std.mem.writeInt(u32, hashplus[0..4], id, .little);
    std.mem.writeInt(u32, hashplus[4..8], std.math.cast(u32, computed.total_size) orelse std.math.maxInt(u32), .little);
    hashplus[8..].* = computed.digest[0..25].*;

    var encoded: [44]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &hashplus);

    return std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{ name, version, &encoded });
}

test formatHash {
    // The example from the tests in Zig's own `src/Package.zig`.
    const digest: [32]u8 = .{
        0xc7, 0xf5, 0x71, 0xb7, 0xb4, 0xe7, 0x6f, 0x3c, 0xdb, 0x87, 0x7a, 0x7f, 0xdd, 0xf9, 0x77, 0x87,
        0x9d, 0xd3, 0x86, 0xfa, 0x73, 0x57, 0x9a, 0xf7, 0x9d, 0x1e, 0xdb, 0x8f, 0x3a, 0xd9, 0xbd, 0x9f,
    };
    const hash = try formatHash(std.testing.allocator, .{ .digest = digest, .total_size = 10 * 1024 * 1024 }, "nasm", "2.16.1-3", 0xcafebabe);
    defer std.testing.allocator.free(hash);
    try std.testing.expectEqualStrings("nasm-2.16.1-3-vrr-ygAAoADH9XG3tOdvPNuHen_d-XeHndOG-nNXmved", hash);
}

test stripRoot {
    try std.testing.expectEqualStrings("src/main.zig", stripRoot("pkg/src/main.zig", "pkg"));
    try std.testing.expectEqualStrings("pkgs/main.zig", stripRoot("pkgs/main.zig", "pkg"));
    try std.testing.expectEqualStrings("main.zig", stripRoot("main.zig", ""));
}

test "Filter.includePath" {
    const gpa = std.testing.allocator;
    var filter: Filter = .{};
    defer filter.include_paths.deinit(gpa);

    try std.testing.expect(filter.includePath(".gitignore"));

    try filter.include_paths.put(gpa, "src", {});
    try std.testing.expect(filter.includePath("src/core/unix/SDL_poll.c"));
    try std.testing.expect(!filter.includePath(".gitignore"));
    try std.testing.expect(!filter.includePath("srcs/file.c"));
}
