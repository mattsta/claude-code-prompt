const std = @import("std");

pub const RESET = "\x1b[0m";
pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const BLUE = "\x1b[34m";
pub const MAGENTA = "\x1b[35m";
pub const CYAN = "\x1b[36m";
pub const DIM = "\x1b[2m";

pub fn visibleLen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and s[i] != 'm') : (i += 1) {}
            if (i < s.len) i += 1;
            continue;
        }
        n += 1;
        i += 1;
    }
    return n;
}

test "visibleLen strips ansi" {
    try std.testing.expectEqual(@as(usize, 0), visibleLen(""));
    try std.testing.expectEqual(@as(usize, 5), visibleLen("hello"));
    try std.testing.expectEqual(@as(usize, 5), visibleLen(RED ++ "hello" ++ RESET));
    try std.testing.expectEqual(@as(usize, 11), visibleLen(DIM ++ "a" ++ RESET ++ "b" ++ CYAN ++ "ccccccccc" ++ RESET));
}
