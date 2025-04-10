# Practice Project Http Server In Zig

This is a side project for my own learning. If you really want me to be real, I would say to not use it. What I have at the moment is very likely to change.

## Usage

### Server

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

### Client

```zig
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
```
