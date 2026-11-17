//! The manual backend: a surface with no pty and no child process.
//!
//! The embedder feeds the terminal with bytes (`Termio.processOutput`, the C
//! function `ghostty_surface_feed`). Everything that a pty would receive
//! (key input, pastes, terminal replies such as device attributes, focus
//! and size reports) goes out through the `write` callback. A change of the
//! grid or pixel size goes out through the `resize` callback.
//!
//! Both callbacks run on the termio thread, and either can run with the
//! renderer state lock held (size, focus and color-scheme reports, and the
//! resize callback itself). A callback must therefore not call a libghostty
//! function that takes that lock (`ghostty_surface_feed`,
//! `ghostty_surface_read_text`, and others). It must not take a lock that a
//! thread holds while it calls `ghostty_surface_feed`, and it must not block
//! for long. Copy what it needs and return.
const Manual = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

/// Receives bytes that the terminal sends to the program. The pointer is
/// valid only during the call. Called in order, from the termio thread.
pub const WriteFn = *const fn (
    userdata: ?*anyopaque,
    data: [*]const u8,
    len: usize,
) callconv(.c) void;

/// Receives the new size of the terminal. Called from the termio thread,
/// with the renderer state lock held, each time that the size changes.
pub const ResizeFn = *const fn (
    userdata: ?*anyopaque,
    columns: u16,
    rows: u16,
    width_px: u32,
    height_px: u32,
) callconv(.c) void;

pub const Config = struct {
    userdata: ?*anyopaque = null,
    write: ?WriteFn = null,
    resize: ?ResizeFn = null,
};

config: Config,

pub fn init(config: Config) Manual {
    return .{ .config = config };
}

pub fn deinit(self: *Manual) void {
    _ = self;
}

/// There is no pty, so there is nothing to set up on the terminal.
pub fn initTerminal(self: *Manual, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
}

pub fn threadEnter(
    self: *Manual,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = self;
    _ = alloc;
    _ = io;
    td.backend = .{ .manual = {} };
}

pub fn threadExit(self: *Manual, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
}

pub fn focusGained(
    self: *Manual,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Manual,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    const cb = self.config.resize orelse return;
    cb(
        self.config.userdata,
        grid_size.columns,
        grid_size.rows,
        screen_size.width,
        screen_size.height,
    );
}

/// Send bytes to the program, through the write callback. In linefeed mode
/// each CR becomes CR LF, as the pty backend does.
pub fn queueWrite(
    self: *Manual,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = td;
    const cb = self.config.write orelse return;
    if (data.len == 0) return;

    if (!linefeed) {
        cb(self.config.userdata, data.ptr, data.len);
        return;
    }

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(alloc);
    try list.ensureTotalCapacity(alloc, data.len + 8);
    for (data) |ch| {
        try list.append(alloc, ch);
        if (ch == '\r') try list.append(alloc, '\n');
    }
    cb(self.config.userdata, list.items.ptr, list.items.len);
}

/// There is no process, so there is nothing to report.
pub fn getProcessInfo(self: *Manual, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

const TestSink = struct {
    bytes: std.ArrayList(u8) = .empty,
    size: ?[4]u32 = null,
    writes: usize = 0,

    fn write(ud: ?*anyopaque, data: [*]const u8, len: usize) callconv(.c) void {
        const self: *TestSink = @ptrCast(@alignCast(ud.?));
        self.bytes.appendSlice(std.testing.allocator, data[0..len]) catch @panic("oom");
        self.writes += 1;
    }

    fn resize(ud: ?*anyopaque, cols: u16, rows: u16, w: u32, h: u32) callconv(.c) void {
        const self: *TestSink = @ptrCast(@alignCast(ud.?));
        self.size = .{ cols, rows, w, h };
    }
};

fn testTd() termio.Termio.ThreadData {
    return .{
        .alloc = std.testing.allocator,
        .loop = undefined,
        .renderer_state = undefined,
        .surface_mailbox = undefined,
        .backend = .{ .manual = {} },
        .mailbox = undefined,
    };
}

test "manual: input goes out through the write callback" {
    var sink: TestSink = .{};
    defer sink.bytes.deinit(std.testing.allocator);
    var m: Manual = .init(.{
        .userdata = &sink,
        .write = TestSink.write,
        .resize = TestSink.resize,
    });
    var td = testTd();

    try m.queueWrite(std.testing.allocator, &td, "ls\r", false);
    try m.queueWrite(std.testing.allocator, &td, "\x1b[?62;22c", false);
    try std.testing.expectEqualStrings("ls\r\x1b[?62;22c", sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 2), sink.writes);

    // An empty write does not call out.
    try m.queueWrite(std.testing.allocator, &td, "", false);
    try std.testing.expectEqual(@as(usize, 2), sink.writes);
}

test "manual: linefeed mode turns CR into CR LF" {
    var sink: TestSink = .{};
    defer sink.bytes.deinit(std.testing.allocator);
    var m: Manual = .init(.{ .userdata = &sink, .write = TestSink.write });
    var td = testTd();

    try m.queueWrite(std.testing.allocator, &td, "a\rb\r", true);
    try std.testing.expectEqualStrings("a\r\nb\r\n", sink.bytes.items);
}

test "manual: size goes out through the resize callback" {
    var sink: TestSink = .{};
    defer sink.bytes.deinit(std.testing.allocator);
    var m: Manual = .init(.{ .userdata = &sink, .resize = TestSink.resize });

    try m.resize(
        .{ .columns = 120, .rows = 40 },
        .{ .width = 1200, .height = 800 },
    );
    try std.testing.expectEqual([4]u32{ 120, 40, 1200, 800 }, sink.size.?);
}

test "manual: no callbacks is a safe no-op" {
    var m: Manual = .init(.{});
    var td = testTd();
    try m.queueWrite(std.testing.allocator, &td, "x", true);
    try m.resize(.{ .columns = 1, .rows = 1 }, .{ .width = 1, .height = 1 });
    try std.testing.expect(m.getProcessInfo(.foreground_pid) == null);
}
