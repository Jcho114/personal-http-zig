# Http-Zig

## Notes

This is a side project for my own benefit. What I have at the moment is very likely to change.

## Usagae

### Server

```zig
const std = @import("std");
const http = @import("http.zig");

pub fn testGetHandler(_: *http.Request, response: *http.Response) !void {
    response.* = .{
        .statusCode = 200,
        .statusText = "Ok",
        .body = "test get handler",
    };
}

pub fn main() !void {
    var httpServer = try http.HttpServer.init(8080);
    defer httpServer.deinit();
    try httpServer.route("GET /test", testGetHandler);
    try httpServer.run();
}
```

### Client

```zig
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
```
