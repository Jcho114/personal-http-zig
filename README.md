# Http-Zig

This is a side project for my own benefit. If you really want me to be real, I would say to not use it. What I have at the moment is very likely to change.

## Usage

### Server

```zig
const std = @import("std");
const http = @import("http");

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
const http = @import("http");

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

## Installation

1. Add http-zig as a dependency in your `build.zig.zon` file

```bash
zig fetch --save git+https://github.com/Jcho114/http-zig#main
```

2. Add the module as a dependency in your `build.zig` file

```zig
const http = b.dependency("http-zig", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("http", http.module("http"));
```
