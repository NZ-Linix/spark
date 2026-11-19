const std = @import("std");

pub const url = "https://github.com/NZ-Linix/spark/issues";

test "feedback URL stays on the spark.sh domain" {
    try std.testing.expectEqualStrings("https://github.com/NZ-Linix/spark/issues", url);
}
