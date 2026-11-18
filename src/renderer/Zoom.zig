//! The zoom of a surface's picture: a view transform that scales what the
//! surface draws about an anchor point and then pans it, as a pinch zooms
//! a page in a browser. The font size, the grid and the pty size never
//! change. Every other position (cells, smooth-scroll shifts, region
//! scrolls, padding) stays in base surface pixels, and the zoom applies
//! last.
//!
//! `forward` takes a base surface point to the point on screen where the
//! zoomed picture draws it. `inverse` takes a point on screen back to the
//! base surface point drawn there. The surface applies the inverse once,
//! where a pointer becomes a cell (`Surface.posToViewport`), and the
//! forward once, where a cell becomes a point for the host (`imePoint`).
//!
//! All values are in surface pixels.
const Zoom = @This();

const std = @import("std");
const testing = std.testing;
const size = @import("size.zig");

/// The largest scale. A zoomed glyph atlas doubles in steps, so above 3x
/// it costs 2.5 to 4 times the memory of 3x (design 012, experiment E3).
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

test "pane zoom: a point on screen hits the cell drawn there, grid unchanged" {
    const s: size.Size = .{
        .screen = .{ .width = 1610, .height = 1034 },
        .cell = .{ .width = 16, .height = 34 },
        .padding = .{ .top = 8, .bottom = 8, .left = 5, .right = 5 },
    };
    const before = s.grid();
    const z = resolve(.{
        .scale = 3,
        .anchor_x = 700,
        .anchor_y = 300,
        .pan_x = 90,
        .pan_y = -40,
    }, @floatFromInt(s.screen.width), @floatFromInt(s.screen.height));

    // The center of every cell, drawn zoomed, hit tests to that cell.
    var row: u32 = 0;
    while (row < before.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < before.columns) : (col += 1) {
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

    // The zoom is a view transform: the grid is what it was.
    const after = s.grid();
    try testing.expectEqual(before.columns, after.columns);
    try testing.expectEqual(before.rows, after.rows);
}
