const std = @import("std");

/// Format an integer like the Python helper: "Xk" when ≥10000, "X.Yk" when ≥1000, else "N".
pub fn k(buf: []u8, n: u64) []const u8 {
    if (n >= 10_000) {
        const rounded = (n + 500) / 1000;
        return std.fmt.bufPrint(buf, "{d}k", .{rounded}) catch unreachable;
    }
    if (n >= 1_000) {
        const tenths = (n + 50) / 100; // round to one decimal in units of 0.1k
        return std.fmt.bufPrint(buf, "{d}.{d}k", .{ tenths / 10, tenths % 10 }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
}

/// Format a USD amount as "X,XXX.YY" (matches Python "${cost:,.2f}").
pub fn money(buf: []u8, usd: f64) []const u8 {
    const sign = usd < 0;
    const abs = if (sign) -usd else usd;
    const total_cents: u64 = @intFromFloat(@round(abs * 100.0));
    const dollars = total_cents / 100;
    const cents = total_cents % 100;
    var dbuf: [32]u8 = undefined;
    const dollar_str = commas(&dbuf, dollars);
    if (sign) {
        return std.fmt.bufPrint(buf, "-{s}.{d:0>2}", .{ dollar_str, cents }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{s}.{d:0>2}", .{ dollar_str, cents }) catch unreachable;
}

/// Write `n` with comma thousand separators ("3,531"). Returns the slice.
pub fn commas(buf: []u8, n: u64) []const u8 {
    var raw_buf: [32]u8 = undefined;
    const raw = std.fmt.bufPrint(&raw_buf, "{d}", .{n}) catch unreachable;
    var out_len: usize = 0;
    for (raw, 0..) |c, i| {
        const remaining = raw.len - i;
        if (i > 0 and remaining % 3 == 0) {
            buf[out_len] = ',';
            out_len += 1;
        }
        buf[out_len] = c;
        out_len += 1;
    }
    return buf[0..out_len];
}

/// Format a milliseconds duration as "Ns" / "NmMMs" / "NhMMm".
pub fn durationMs(buf: []u8, ms: u64) []const u8 {
    const secs = ms / 1000;
    if (secs < 60) return std.fmt.bufPrint(buf, "{d}s", .{secs}) catch unreachable;
    const total_min = secs / 60;
    const sec_rem = secs % 60;
    if (total_min < 60) return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ total_min, sec_rem }) catch unreachable;
    const hours = total_min / 60;
    const min_rem = total_min % 60;
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ hours, min_rem }) catch unreachable;
}

/// Format "time until" in seconds: "now" if ≤0, "Nm", "NhMMm", "NdHHh".
pub fn until(buf: []u8, secs: i64) []const u8 {
    if (secs <= 0) return std.fmt.bufPrint(buf, "now", .{}) catch unreachable;
    const s: u64 = @intCast(secs);
    const total_min = s / 60;
    if (total_min < 60) return std.fmt.bufPrint(buf, "{d}m", .{total_min}) catch unreachable;
    const total_hr = total_min / 60;
    const min_rem = total_min % 60;
    if (total_hr < 24) return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ total_hr, min_rem }) catch unreachable;
    const days = total_hr / 24;
    const hr_rem = total_hr % 24;
    return std.fmt.bufPrint(buf, "{d}d{d:0>2}h", .{ days, hr_rem }) catch unreachable;
}

test "k formatter" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", k(&buf, 0));
    try std.testing.expectEqualStrings("999", k(&buf, 999));
    try std.testing.expectEqualStrings("1.0k", k(&buf, 1000));
    try std.testing.expectEqualStrings("1.5k", k(&buf, 1500));
    try std.testing.expectEqualStrings("9.9k", k(&buf, 9949));
    try std.testing.expectEqualStrings("10k", k(&buf, 10_000));
    try std.testing.expectEqualStrings("103k", k(&buf, 102_531));
    try std.testing.expectEqualStrings("7554k", k(&buf, 7_554_000));
}

test "durationMs formatter" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0s", durationMs(&buf, 0));
    try std.testing.expectEqualStrings("45s", durationMs(&buf, 45_000));
    try std.testing.expectEqualStrings("1m05s", durationMs(&buf, 65_000));
    try std.testing.expectEqualStrings("1h17m", durationMs(&buf, (1 * 3600 + 17 * 60) * 1000));
    try std.testing.expectEqualStrings("33h38m", durationMs(&buf, (33 * 3600 + 38 * 60) * 1000));
}

test "money formatter" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0.00", money(&buf, 0));
    try std.testing.expectEqualStrings("25.40", money(&buf, 25.3960692));
    try std.testing.expectEqualStrings("25.40", money(&buf, 25.40));
    try std.testing.expectEqualStrings("2,594.51", money(&buf, 2594.51));
    try std.testing.expectEqualStrings("1,000,000.00", money(&buf, 1_000_000));
}

test "commas formatter" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", commas(&buf, 0));
    try std.testing.expectEqualStrings("999", commas(&buf, 999));
    try std.testing.expectEqualStrings("3,531", commas(&buf, 3531));
    try std.testing.expectEqualStrings("106,753", commas(&buf, 106_753));
    try std.testing.expectEqualStrings("1,000,000", commas(&buf, 1_000_000));
}

test "until formatter" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("now", until(&buf, 0));
    try std.testing.expectEqualStrings("now", until(&buf, -100));
    try std.testing.expectEqualStrings("0m", until(&buf, 30));
    try std.testing.expectEqualStrings("44m", until(&buf, 45 * 60 - 1));
    try std.testing.expectEqualStrings("2h11m", until(&buf, 2 * 3600 + 12 * 60 - 1));
    try std.testing.expectEqualStrings("3d03h", until(&buf, 3 * 86400 + 4 * 3600 - 1));
    try std.testing.expectEqualStrings("6d00h", until(&buf, 6 * 86400 + 30));
}
