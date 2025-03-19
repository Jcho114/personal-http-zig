const std = @import("std");
const http = @import("http");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const client = try http.HttpClient.init(.{
        .allocator = allocator,
    });
    defer client.deinit();

    const request = try http.Request.init(allocator);
    defer request.deinit();
    request.method = http.Method.POST;
    request.target = "/";
    request.protocol = "HTTP/1.1";
    request.body = "testbody";
    std.debug.print("{}\n", .{request});

    const response = try client.send("127.0.0.1", 8080, request);
    defer response.deinit();
    std.debug.print("{}\n", .{response});
}
