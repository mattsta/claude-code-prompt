const std = @import("std");

pub const Model = struct { display_name: ?[]const u8 = null };
pub const Workspace = struct { current_dir: ?[]const u8 = null };
pub const Cost = struct {
    total_cost_usd: ?f64 = null,
    total_lines_added: ?u64 = null,
    total_lines_removed: ?u64 = null,
    total_api_duration_ms: ?u64 = null,
};
pub const CurrentUsage = struct {
    input_tokens: ?u64 = null,
    cache_creation_input_tokens: ?u64 = null,
    cache_read_input_tokens: ?u64 = null,
};
pub const ContextWindow = struct {
    total_input_tokens: ?u64 = null,
    total_output_tokens: ?u64 = null,
    context_window_size: ?u64 = null,
    current_usage: ?CurrentUsage = null,
};
pub const Effort = struct { level: ?[]const u8 = null };
pub const Thinking = struct { enabled: ?bool = null };
pub const RateWindow = struct {
    used_percentage: ?f64 = null,
    resets_at: ?i64 = null,
};
pub const RateLimits = struct {
    five_hour: ?RateWindow = null,
    seven_day: ?RateWindow = null,
};

pub const Status = struct {
    model: ?Model = null,
    workspace: ?Workspace = null,
    cwd: ?[]const u8 = null,
    cost: ?Cost = null,
    context_window: ?ContextWindow = null,
    effort: ?Effort = null,
    thinking: ?Thinking = null,
    rate_limits: ?RateLimits = null,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Status) {
    return std.json.parseFromSlice(Status, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
}

test "parse minimal input" {
    const input =
        \\{"model": {"display_name": "Opus 4.5"}, "context_window": {"total_input_tokens": 100, "current_usage": {"input_tokens": 5, "cache_read_input_tokens": 95}}}
    ;
    const parsed = try parse(std.testing.allocator, input);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Opus 4.5", parsed.value.model.?.display_name.?);
    try std.testing.expectEqual(@as(?u64, 100), parsed.value.context_window.?.total_input_tokens);
    try std.testing.expectEqual(@as(?u64, 95), parsed.value.context_window.?.current_usage.?.cache_read_input_tokens);
}

test "parse ignores unknown fields" {
    const input =
        \\{"some_future_field": 42, "transcript_path": "/tmp/x", "model": {"id": "x", "display_name": "Y"}}
    ;
    const parsed = try parse(std.testing.allocator, input);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Y", parsed.value.model.?.display_name.?);
}

test "parse rate_limits" {
    const input =
        \\{"rate_limits": {"five_hour": {"used_percentage": 67.5, "resets_at": 1738425600}, "seven_day": {"used_percentage": 92, "resets_at": 1738857600}}}
    ;
    const parsed = try parse(std.testing.allocator, input);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 67.5), parsed.value.rate_limits.?.five_hour.?.used_percentage.?);
    try std.testing.expectEqual(@as(i64, 1738857600), parsed.value.rate_limits.?.seven_day.?.resets_at.?);
}
