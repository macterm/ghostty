//! The zoom of a surface's picture. It is a view transform: it scales the
//! picture about an anchor point, then pans it. The font size, the grid
//! and the pty size do not change. Every other position (cells,
//! smooth-scroll shifts, region scrolls, padding) stays in base surface
//! pixels, and the zoom applies last.
//!
//! `forward` takes a base surface point to the point on screen where the
//! zoomed picture draws it. `inverse` takes a point on screen back to the
//! base surface point drawn there. The surface applies the inverse where
//! a pointer becomes a cell, and the forward where a cell becomes a point
//! for the host (see `Surface.zoom`).
//!
//! All values are in surface pixels.
const Zoom = @This();

const std = @import("std");
const testing = std.testing;
const size = @import("size.zig");

/// The largest scale. A zoomed glyph atlas doubles in steps, so 4x costs
/// 2.5 to 4 times the memory of 3x.
pub const max_scale: f64 = 3;

/// 1 is no zoom. The picture never zooms out: outside the grid there is
/// nothing to draw.
scale: f64 = 1,

/// The point that stays in place when the scale changes.
anchor_x: f64 = 0,
anchor_y: f64 = 0,

/// The move of the zoomed picture after the scale.
pan_x: f64 = 0,
pan_y: f64 = 0,

pub const identity: Zoom = .{};

/// The zoom to draw for a request on a surface of `width` x `height`
/// pixels. The scale is clamped to 1 through `max_scale`, the anchor to
/// the surface, and the pan so that the zoomed picture covers all of the
/// surface. A request with a value that is not finite is no zoom.
///
/// The surface keeps the request and resolves it at each use, so a resize
/// clamps the pan again with nothing to remember.
pub fn resolve(request: Zoom, width: f64, height: f64) Zoom {
    const values = [_]f64{
        request.scale,
        request.anchor_x,
        request.anchor_y,
        request.pan_x,
        request.pan_y,
        width,
        height,
    };
    for (values) |v| {
        if (!std.math.isFinite(v)) return identity;
    }
    if (width <= 0 or height <= 0) return identity;

    const scale = std.math.clamp(request.scale, 1, max_scale);
    if (scale == 1) return identity;

    const ax = std.math.clamp(request.anchor_x, 0, width);
    const ay = std.math.clamp(request.anchor_y, 0, height);
    return .{
        .scale = scale,
        .anchor_x = ax,
        .anchor_y = ay,
        .pan_x = clampPan(request.pan_x, ax, width, scale),
        .pan_y = clampPan(request.pan_y, ay, height, scale),
    };
}

/// The pan on one axis that keeps the zoomed edges outside the surface:
/// the near edge `forward(0) <= 0` and the far edge `forward(len) >= len`.
fn clampPan(pan: f64, anchor: f64, len: f64, scale: f64) f64 {
    const grow = scale - 1;
    return std.math.clamp(pan, -(len - anchor) * grow, anchor * grow);
}

pub fn isIdentity(self: Zoom) bool {
    return self.scale == 1 and self.pan_x == 0 and self.pan_y == 0;
}

/// The point on screen where the picture draws the base point (`x`, `y`).
pub fn forward(self: Zoom, x: f64, y: f64) size.Coordinate.Surface {
    return .{
        .x = self.anchor_x + self.scale * (x - self.anchor_x) + self.pan_x,
        .y = self.anchor_y + self.scale * (y - self.anchor_y) + self.pan_y,
    };
}

/// The base point that the picture draws at the screen point (`x`, `y`).
pub fn inverse(self: Zoom, x: f64, y: f64) size.Coordinate.Surface {
    return .{
        .x = self.anchor_x + (x - self.anchor_x - self.pan_x) / self.scale,
        .y = self.anchor_y + (y - self.anchor_y - self.pan_y) / self.scale,
    };
}

/// The zoom as the picture draws it on a surface of size `s`. The
/// renderer draws with it, and the surface hit tests with it, so the two
/// always agree.
///
/// A zoomed cell is a whole number of pixels, `round(scale x cell)` on
/// each axis, so that box drawing and block glyphs tile with no gap. The
/// scale on each axis is that cell over the base cell, so it can be a
/// little different from the request (under 2% from 2x). The grid's
/// top-left corner draws on a whole pixel, so a glyph from the zoomed
/// glyph atlas lands on whole pixels too.
pub fn view(request: Zoom, s: size.Size) View {
    const width: f64 = @floatFromInt(s.screen.width);
    const height: f64 = @floatFromInt(s.screen.height);
    const z = request.resolve(width, height);
    if (z.scale == 1 or s.cell.width == 0 or s.cell.height == 0) {
        return .identity;
    }

    const cell = zoomedCell(z.scale, s.cell);
    const sx = @as(f64, @floatFromInt(cell.width)) / @as(f64, @floatFromInt(s.cell.width));
    const sy = @as(f64, @floatFromInt(cell.height)) / @as(f64, @floatFromInt(s.cell.height));
    return .{
        .scale = z.scale,
        .scale_x = sx,
        .scale_y = sy,
        .offset_x = viewOffset(z.anchor_x, z.pan_x, sx, width, s.padding.left),
        .offset_y = viewOffset(z.anchor_y, z.pan_y, sy, height, s.padding.top),
    };
}

/// The whole-pixel size of a cell at `scale`.
pub fn zoomedCell(scale: f64, cell: size.CellSize) size.CellSize {
    return .{
        .width = @intFromFloat(@round(scale * @as(f64, @floatFromInt(cell.width)))),
        .height = @intFromFloat(@round(scale * @as(f64, @floatFromInt(cell.height)))),
    };
}

/// The offset on one axis of `View`: the request's anchor and pan at the
/// axis scale `s`, then moved by less than a pixel so that the grid's
/// first cell (at `pad`) draws on a whole pixel. It stays in the range
/// that keeps the surface covered: `offset <= 0` and
/// `s * len + offset >= len`.
fn viewOffset(anchor: f64, pan: f64, s: f64, len: f64, pad: u32) f64 {
    const p: f64 = @floatFromInt(pad);
    const lo = len * (1 - s);
    const raw = std.math.clamp(anchor * (1 - s) + pan, lo, 0);
    // Where the grid's first cell draws; a whole pixel if one is in range.
    const first = s * p + raw;
    const first_lo = @ceil(s * p + lo);
    const first_hi = @floor(s * p);
    if (first_lo > first_hi) return raw;
    return std.math.clamp(@round(first), first_lo, first_hi) - s * p;
}

/// The zoom as drawn: a point `p` of the base surface draws at
/// `scale_* * p + offset_*`. See `view`.
pub const View = struct {
    /// The scale of the request, after the clamp. The zoomed glyph atlas
    /// is built at the font size times this.
    scale: f64 = 1,
    scale_x: f64 = 1,
    scale_y: f64 = 1,
    offset_x: f64 = 0,
    offset_y: f64 = 0,

    pub const identity: View = .{};

    pub fn isIdentity(self: View) bool {
        return self.scale_x == 1 and self.scale_y == 1 and
            self.offset_x == 0 and self.offset_y == 0;
    }

    /// The point on screen where the picture draws the base point.
    pub fn forward(self: View, x: f64, y: f64) size.Coordinate.Surface {
        return .{
            .x = self.scale_x * x + self.offset_x,
            .y = self.scale_y * y + self.offset_y,
        };
    }

    /// The base point that the picture draws at the screen point.
    pub fn inverse(self: View, x: f64, y: f64) size.Coordinate.Surface {
        return .{
            .x = (x - self.offset_x) / self.scale_x,
            .y = (y - self.offset_y) / self.scale_y,
        };
    }
};

test "pane zoom: identity changes no point" {
    const z = resolve(.{}, 800, 600);
    try testing.expect(z.isIdentity());
    const p = z.forward(123.5, 45.25);
    try testing.expectEqual(@as(f64, 123.5), p.x);
    try testing.expectEqual(@as(f64, 45.25), p.y);
    const q = z.inverse(123.5, 45.25);
    try testing.expectEqual(@as(f64, 123.5), q.x);
    try testing.expectEqual(@as(f64, 45.25), q.y);
}

test "pane zoom: the anchor stays in place" {
    const z = resolve(.{ .scale = 2, .anchor_x = 300, .anchor_y = 200 }, 800, 600);
    const p = z.forward(300, 200);
    try testing.expectEqual(@as(f64, 300), p.x);
    try testing.expectEqual(@as(f64, 200), p.y);
    // A point 10 px right of the anchor draws 20 px right of it.
    try testing.expectEqual(@as(f64, 320), z.forward(310, 200).x);
}

test "pane zoom: scale is clamped to 1 through 3" {
    const small = resolve(.{ .scale = 0.5, .anchor_x = 10, .pan_x = 5 }, 800, 600);
    try testing.expect(small.isIdentity());
    const big = resolve(.{ .scale = 8 }, 800, 600);
    try testing.expectEqual(max_scale, big.scale);
}

test "pane zoom: a value that is not finite is no zoom" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try testing.expect(resolve(.{ .scale = nan }, 800, 600).isIdentity());
    try testing.expect(resolve(.{ .scale = 2, .anchor_x = inf }, 800, 600).isIdentity());
    try testing.expect(resolve(.{ .scale = 2, .pan_y = -inf }, 800, 600).isIdentity());
    try testing.expect(resolve(.{ .scale = 2 }, 0, 600).isIdentity());
}

test "pane zoom: the pan keeps the surface covered" {
    const w: f64 = 800;
    const h: f64 = 600;
    const pans = [_]f64{ -10_000, -500, -1, 0, 1, 500, 10_000 };
    const anchors = [_]f64{ -50, 0, 200, 400, 800, 900 };
    for ([_]f64{ 1.05, 1.5, 2, 3 }) |s| {
        for (anchors) |a| {
            for (pans) |p| {
                const z = resolve(.{
                    .scale = s,
                    .anchor_x = a,
                    .anchor_y = a,
                    .pan_x = p,
                    .pan_y = -p,
                }, w, h);
                const top_left = z.forward(0, 0);
                const bottom_right = z.forward(w, h);
                try testing.expect(top_left.x <= 1e-9);
                try testing.expect(top_left.y <= 1e-9);
                try testing.expect(bottom_right.x >= w - 1e-9);
                try testing.expect(bottom_right.y >= h - 1e-9);
            }
        }
    }
}

test "pane zoom: a pan inside the range is kept" {
    // At 2x about the center the picture can move 400 px each way.
    const z = resolve(.{
        .scale = 2,
        .anchor_x = 400,
        .anchor_y = 300,
        .pan_x = -399,
        .pan_y = 299,
    }, 800, 600);
    try testing.expectEqual(@as(f64, -399), z.pan_x);
    try testing.expectEqual(@as(f64, 299), z.pan_y);
    const edge = resolve(.{ .scale = 2, .anchor_x = 400, .pan_x = 401 }, 800, 600);
    try testing.expectEqual(@as(f64, 400), edge.pan_x);
}

test "pane zoom: inverse is the inverse of forward" {
    const z = resolve(.{
        .scale = 2.5,
        .anchor_x = 170,
        .anchor_y = 430,
        .pan_x = -60,
        .pan_y = 75,
    }, 800, 600);
    const points = [_][2]f64{ .{ 0, 0 }, .{ 800, 600 }, .{ 13.25, 590 }, .{ 401, 17 } };
    for (points) |pt| {
        const there = z.forward(pt[0], pt[1]);
        const back = z.inverse(there.x, there.y);
        try testing.expectApproxEqAbs(pt[0], back.x, 1e-9);
        try testing.expectApproxEqAbs(pt[1], back.y, 1e-9);
        const screen = z.inverse(pt[0], pt[1]);
        const again = z.forward(screen.x, screen.y);
        try testing.expectApproxEqAbs(pt[0], again.x, 1e-9);
        try testing.expectApproxEqAbs(pt[1], again.y, 1e-9);
    }
}

test "pane zoom: each cell drawn zoomed hit tests to that cell" {
    const s: size.Size = .{
        .screen = .{ .width = 1610, .height = 1034 },
        .cell = .{ .width = 16, .height = 34 },
        .padding = .{ .top = 8, .bottom = 8, .left = 5, .right = 5 },
    };
    const grid = s.grid();
    const z = resolve(.{
        .scale = 3,
        .anchor_x = 700,
        .anchor_y = 300,
        .pan_x = 90,
        .pan_y = -40,
    }, @floatFromInt(s.screen.width), @floatFromInt(s.screen.height));

    // The center of every cell, drawn zoomed, hit tests to that cell.
    var row: u32 = 0;
    while (row < grid.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < grid.columns) : (col += 1) {
            const cx: f64 = @floatFromInt(s.padding.left + col * s.cell.width + s.cell.width / 2);
            const cy: f64 = @floatFromInt(s.padding.top + row * s.cell.height + s.cell.height / 2);
            const drawn = z.forward(cx, cy);
            const base = z.inverse(drawn.x, drawn.y);
            const coord: size.Coordinate = .{ .surface = base };
            const cell = coord.convert(.grid, s).grid;
            try testing.expectEqual(col, cell.x);
            try testing.expectEqual(row, cell.y);
        }
    }
}

const test_size: size.Size = .{
    .screen = .{ .width = 1610, .height = 1034 },
    .cell = .{ .width = 16, .height = 34 },
    .padding = .{ .top = 8, .bottom = 8, .left = 5, .right = 5 },
};

test "pane zoom: view of no zoom is the identity" {
    try testing.expect(view(.{}, test_size).isIdentity());
    try testing.expect(view(.{ .scale = 0.5 }, test_size).isIdentity());
    var no_cell = test_size;
    no_cell.cell = .{ .width = 0, .height = 0 };
    try testing.expect(view(.{ .scale = 2 }, no_cell).isIdentity());
}

test "pane zoom: view cells are whole pixels" {
    for ([_]f64{ 1.05, 1.1, 1.25, 1.5, 2, 2.37, 3 }) |sc| {
        const v = view(.{ .scale = sc, .anchor_x = 300, .anchor_y = 200 }, test_size);
        const cell = zoomedCell(sc, test_size.cell);
        try testing.expectEqual(@as(f64, @floatFromInt(cell.width)), v.scale_x * 16);
        try testing.expectEqual(@as(f64, @floatFromInt(cell.height)), v.scale_y * 34);
        try testing.expectEqual(sc, v.scale);
    }
    // 1.1x of 16x34 is 17.6x37.4: drawn as 18x37.
    const c = zoomedCell(1.1, test_size.cell);
    try testing.expectEqual(@as(u32, 18), c.width);
    try testing.expectEqual(@as(u32, 37), c.height);
}

test "pane zoom: view keeps the surface covered and the grid on whole pixels" {
    const w: f64 = @floatFromInt(test_size.screen.width);
    const h: f64 = @floatFromInt(test_size.screen.height);
    const pans = [_]f64{ -10_000, -333.3, -1, 0, 0.4, 1, 271.7, 10_000 };
    const anchors = [_]f64{ -50, 0, 123.4, 805, 1610, 2000 };
    for ([_]f64{ 1.05, 1.1, 1.5, 2, 2.37, 3 }) |sc| {
        for (anchors) |a| {
            for (pans) |p| {
                const v = view(.{
                    .scale = sc,
                    .anchor_x = a,
                    .anchor_y = a / 2,
                    .pan_x = p,
                    .pan_y = -p,
                }, test_size);
                const tl = v.forward(0, 0);
                const br = v.forward(w, h);
                try testing.expect(tl.x <= 1e-9 and tl.y <= 1e-9);
                try testing.expect(br.x >= w - 1e-9 and br.y >= h - 1e-9);
                const first = v.forward(5, 8);
                try testing.expectApproxEqAbs(@round(first.x), first.x, 1e-9);
                try testing.expectApproxEqAbs(@round(first.y), first.y, 1e-9);
            }
        }
    }
}

test "pane zoom: at a whole-pixel scale the view moves the request by less than a pixel" {
    const req: Zoom = .{ .scale = 2, .anchor_x = 400.3, .anchor_y = 300.6, .pan_x = 10.2 };
    const z = req.resolve(1610, 1034);
    const v = view(req, test_size);
    // At 2x the cell is exactly 32x68, so only the rounding moves it.
    try testing.expectEqual(@as(f64, 2), v.scale_x);
    try testing.expectEqual(@as(f64, 2), v.scale_y);
    for ([_][2]f64{ .{ 0, 0 }, .{ 777, 555 } }) |pt| {
        const a = z.forward(pt[0], pt[1]);
        const b = v.forward(pt[0], pt[1]);
        try testing.expect(@abs(a.x - b.x) <= 0.5 + 1e-9);
        try testing.expect(@abs(a.y - b.y) <= 0.5 + 1e-9);
    }
}

test "pane zoom: each cell the view draws hit tests to that cell" {
    const grid = test_size.grid();
    for ([_]f64{ 1.1, 2.37, 3 }) |sc| {
        const v = view(.{
            .scale = sc,
            .anchor_x = 700,
            .anchor_y = 300,
            .pan_x = 90,
            .pan_y = -40,
        }, test_size);
        var row: u32 = 0;
        while (row < grid.rows) : (row += 1) {
            var col: u32 = 0;
            while (col < grid.columns) : (col += 1) {
                // The center of the cell as drawn, from the zoomed cell size.
                const cell = zoomedCell(sc, test_size.cell);
                const origin = v.forward(5, 8);
                const drawn_x = origin.x + @as(f64, @floatFromInt(col * cell.width)) +
                    @as(f64, @floatFromInt(cell.width)) / 2;
                const drawn_y = origin.y + @as(f64, @floatFromInt(row * cell.height)) +
                    @as(f64, @floatFromInt(cell.height)) / 2;
                const coord: size.Coordinate = .{ .surface = v.inverse(drawn_x, drawn_y) };
                const hit = coord.convert(.grid, test_size).grid;
                try testing.expectEqual(col, hit.x);
                try testing.expectEqual(row, hit.y);
            }
        }
    }
}
