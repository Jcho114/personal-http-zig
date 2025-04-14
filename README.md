# Practice Project Http Server In Zig

This is a side project for my own learning. If you really want me to be real, I would say to not use it. What I have at the moment is very likely to change.

## Usage

```zig
const std = @import("std");
const http = @import("http");

pub fn rootHandler(request: *http.Request, response: *http.Response) !void {
    response.status(200);
    response.send(request.target);
}

pub fn testGetHandler(_: *http.Request, response: *http.Response) !void {
    response.status(200);
    response.send("test get handler");
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var httpServer = try http.HttpServer.init(.{
        .allocator = allocator,
        .port = 8080,
    });
    defer httpServer.deinit();

    try httpServer.route("/", rootHandler);
    try httpServer.route("GET /test", testGetHandler);

    try httpServer.run();
}
```