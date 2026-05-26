const std = @import("std");
const ansi = @import("ansi.zig");
const fmt = @import("fmt.zig");
const input = @import("input.zig");

const TERM_WIDTH: usize = 140;
const AUTOCOMPACT_BUFFER: u64 = 33_000;

fn rateLimitColor(pct: u64) []const u8 {
    if (pct < 50) return ansi.GREEN;
    if (pct < 80) return ansi.YELLOW;
    return ansi.RED;
}

fn pctColor(pct: u64) []const u8 {
    return rateLimitColor(pct);
}

/// Build the right-align padded line: left + spaces + right, padded to TERM_WIDTH.
fn renderLine(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]u8 {
    const lv = ansi.visibleLen(left);
    const rv = ansi.visibleLen(right);
    var pad: usize = 2;
    if (TERM_WIDTH > lv + rv + 2) pad = TERM_WIDTH - lv - rv;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, left);
    try buf.appendNTimes(allocator, ' ', pad);
    try buf.appendSlice(allocator, right);
    return buf.toOwnedSlice(allocator);
}

fn shrinkHomeAlloc(allocator: std.mem.Allocator, env: *std.process.Environ.Map, cwd: []const u8) ![]u8 {
    const home = env.get("HOME") orelse "";
    if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
        const rest = cwd[home.len..];
        return std.fmt.allocPrint(allocator, "~{s}", .{rest});
    }
    return allocator.dupe(u8, cwd);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // ---- read stdin ----
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const reader = &stdin_reader.interface;
    const json_bytes = reader.allocRemaining(gpa, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("statusline: stdin read error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer gpa.free(json_bytes);

    // ---- stdout writer ----
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    // ---- parse JSON ----
    const parsed = input.parse(gpa, json_bytes) catch {
        try stdout.writeAll("[?] error");
        try stdout.flush();
        return;
    };
    defer parsed.deinit();
    const s = parsed.value;

    // ---- extract / compute ----
    const model_name = if (s.model) |m| (m.display_name orelse "?") else "?";

    const ctx = s.context_window;
    const total_in: u64 = if (ctx) |c| (c.total_input_tokens orelse 0) else 0;
    const total_out: u64 = if (ctx) |c| (c.total_output_tokens orelse 0) else 0;
    const ctx_size: u64 = if (ctx) |c| (c.context_window_size orelse 200_000) else 200_000;
    const usable_ctx: u64 = if (ctx_size > AUTOCOMPACT_BUFFER) ctx_size - AUTOCOMPACT_BUFFER else ctx_size;

    var current_ctx: u64 = 0;
    var approx: []const u8 = "";
    if (ctx) |c| if (c.current_usage) |cu| {
        current_ctx = (cu.input_tokens orelse 0) + (cu.cache_creation_input_tokens orelse 0) + (cu.cache_read_input_tokens orelse 0);
    };
    if (current_ctx == 0) {
        current_ctx = total_in + total_out;
        approx = "~";
    }

    const pct: u64 = if (usable_ctx > 0) (current_ctx * 100) / usable_ctx else 0;

    // ---- cost ----
    const cost_usd: f64 = if (s.cost) |co| (co.total_cost_usd orelse 0) else 0;
    const lines_added: u64 = if (s.cost) |co| (co.total_lines_added orelse 0) else 0;
    const lines_removed: u64 = if (s.cost) |co| (co.total_lines_removed orelse 0) else 0;
    const api_ms: u64 = if (s.cost) |co| (co.total_api_duration_ms orelse 0) else 0;

    // ---- prompt: user@host:cwd ----
    const user = init.environ_map.get("USER") orelse "?";
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const full_host = std.posix.gethostname(&host_buf) catch "?";
    const dot = std.mem.indexOfScalar(u8, full_host, '.');
    const host = if (dot) |d| full_host[0..d] else full_host;

    var cwd_buf: [4096]u8 = undefined;
    const cwd_raw: []const u8 = blk: {
        if (s.workspace) |w| if (w.current_dir) |cd| break :blk cd;
        if (s.cwd) |c| break :blk c;
        if (std.c.getcwd(&cwd_buf, cwd_buf.len)) |_| {
            break :blk std.mem.sliceTo(&cwd_buf, 0);
        }
        break :blk ".";
    };
    const cwd = try shrinkHomeAlloc(gpa, init.environ_map, cwd_raw);
    defer gpa.free(cwd);

    // ---- build line 1 ----
    const line1_left = try std.fmt.allocPrint(gpa, "{s}{s}{s}@{s}{s}{s}:{s}{s}{s}", .{
        ansi.RED, user, ansi.RESET, ansi.MAGENTA, host, ansi.RESET, ansi.BLUE, cwd, ansi.RESET,
    });
    defer gpa.free(line1_left);

    var l1r_buf: std.ArrayList(u8) = .empty;
    defer l1r_buf.deinit(gpa);
    try l1r_buf.print(gpa, "{s}{s}{s}", .{ ansi.CYAN, model_name, ansi.RESET });
    if (s.effort) |e| if (e.level) |lvl| {
        try l1r_buf.print(gpa, "  {s}e:{s}{s}{s}{s}", .{ ansi.DIM, ansi.RESET, ansi.CYAN, lvl, ansi.RESET });
    };
    if (s.thinking) |t| if (t.enabled orelse false) {
        try l1r_buf.print(gpa, " {s}+T{s}", .{ ansi.CYAN, ansi.RESET });
    };
    const line1 = try renderLine(gpa, line1_left, l1r_buf.items);
    defer gpa.free(line1);

    // ---- build line 2 ----
    var stats_buf: std.ArrayList(u8) = .empty;
    defer stats_buf.deinit(gpa);
    var nbuf1: [32]u8 = undefined;
    var nbuf2: [32]u8 = undefined;
    var nbuf3: [32]u8 = undefined;
    var nbuf4: [32]u8 = undefined;
    var nbuf5: [32]u8 = undefined;
    var nbuf6: [32]u8 = undefined;
    var nbuf7: [32]u8 = undefined;
    var nbuf8: [32]u8 = undefined;
    try stats_buf.print(gpa, "in:{s}{s}{s} out:{s}{s}{s} | ctx:{s}{s}{d}%{s} {s}({s}/{s}){s} | {s}+{s}{s};{s}-{s}{s} | {s}{s}{s} {s}${s}{s}", .{
        ansi.YELLOW,                       fmt.k(&nbuf1, total_in),  ansi.RESET,
        ansi.YELLOW,                       fmt.k(&nbuf2, total_out), ansi.RESET,
        pctColor(pct),                     approx,                   pct,
        ansi.RESET,                        ansi.DIM,                 fmt.k(&nbuf3, current_ctx),
        fmt.k(&nbuf4, usable_ctx),         ansi.RESET,               ansi.GREEN,
        fmt.commas(&nbuf6, lines_added),   ansi.RESET,               ansi.RED,
        fmt.commas(&nbuf7, lines_removed), ansi.RESET,               ansi.DIM,
        fmt.durationMs(&nbuf5, api_ms),    ansi.RESET,               ansi.MAGENTA,
        fmt.money(&nbuf8, cost_usd),       ansi.RESET,
    });

    // rate limits (optional)
    var rl_buf: std.ArrayList(u8) = .empty;
    defer rl_buf.deinit(gpa);
    if (s.rate_limits) |rl| {
        const now: i64 = std.Io.Clock.real.now(io).toSeconds();
        const RlBit = struct { label: []const u8, win: ?input.RateWindow };
        const bits = [_]RlBit{
            .{ .label = "5h", .win = rl.five_hour },
            .{ .label = "7D", .win = rl.seven_day },
        };
        var any = false;
        for (bits) |b| {
            const w = b.win orelse continue;
            const p_f = w.used_percentage orelse continue;
            const p: u64 = @intFromFloat(@max(0.0, p_f));
            if (any) {
                try rl_buf.print(gpa, " {s}|{s} ", .{ ansi.DIM, ansi.RESET });
            } else {
                try rl_buf.print(gpa, "{s}[{s}", .{ ansi.DIM, ansi.RESET });
                any = true;
            }
            try rl_buf.print(gpa, "{s}{s}:{s}{s}{d}%{s}", .{ ansi.DIM, b.label, ansi.RESET, rateLimitColor(p), p, ansi.RESET });
            if (w.resets_at) |r| {
                var ubuf: [16]u8 = undefined;
                const u = fmt.until(&ubuf, r - now);
                try rl_buf.print(gpa, " {s}({s}){s}", .{ ansi.DIM, u, ansi.RESET });
            }
        }
        if (any) try rl_buf.print(gpa, "{s}]{s}", .{ ansi.DIM, ansi.RESET });
    }

    const line2: []const u8 = blk: {
        if (rl_buf.items.len > 0) {
            break :blk try renderLine(gpa, stats_buf.items, rl_buf.items);
        }
        break :blk try renderLine(gpa, "", stats_buf.items);
    };
    defer gpa.free(line2);

    try stdout.print("{s}\n{s}", .{ line1, line2 });
    try stdout.flush();
}

test "renderLine pads to TERM_WIDTH" {
    const out = try renderLine(std.testing.allocator, "L", "R");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, TERM_WIDTH), out.len);
    try std.testing.expectEqualStrings("L", out[0..1]);
    try std.testing.expectEqualStrings("R", out[out.len - 1 ..]);
}

test "renderLine clamps when content overflows" {
    const long_left = "x" ** (TERM_WIDTH - 1);
    const long_right = "y" ** 10;
    const out = try renderLine(std.testing.allocator, long_left, long_right);
    defer std.testing.allocator.free(out);
    // pad clamped to 2; total = (W-1) + 2 + 10
    try std.testing.expectEqual(@as(usize, (TERM_WIDTH - 1) + 2 + 10), out.len);
}
