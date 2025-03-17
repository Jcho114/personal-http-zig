const std = @import("std");
const http = @import("http.zig");

pub fn main() !void {
    const client = try http.HttpClient.init("127.0.0.1", 8080);
    defer client.deinit();
    const request = try http.Request.init();
    request.* = .{
        .method = http.Method.POST,
        .target = "/",
        .body = "testbody",
    };
    const response = try client.send(request);
    std.debug.print("{}\n", .{response});
}
