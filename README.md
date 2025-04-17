# Practice Project Http Server In Zig

This is a side project for my own learning. If you really want me to be real, I would say to not use it. What I have at the moment is very likely to change.

## Usage

```zig
const std = @import("std");
const http = @import("http");
const JsonObject = http.JsonObject;

pub fn rootHandler(request: *http.Request, response: *http.Response) !void {
    response.status(200);
    response.send(request.target);
}

pub fn testGetHandler(_: *http.Request, response: *http.Response) !void {
    const object = try JsonObject.init(response.allocator);
    defer object.deinit();
    try object.put(.string, "message", "test get handler");
    response.status(200);
    try response.jsonObject(object);
}

pub fn testParamHandler(request: *http.Request, response: *http.Response) !void {
    response.status(200);
    response.send(request.param("param") orelse "unknown");
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const options = try http.HttpServer.HttpServerOptions.default(allocator);
    var httpServer = try http.HttpServer.init(options);
    defer httpServer.deinit();

    try httpServer.route("/", rootHandler);
    try httpServer.route("GET /test", testGetHandler);
    try httpServer.route("/:param/test", testParamHandler);

    try httpServer.run();
}
```
