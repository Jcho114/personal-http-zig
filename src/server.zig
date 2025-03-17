const std = @import("std");
const http = @import("http.zig");

pub fn rootHandler(request: *http.Request, response: *http.Response) !void {
    response.* = .{
        .statusCode = 200,
        .statusText = "Ok",
        .body = request.target,
    };
}

pub fn main() !void {
    var httpServer = try http.HttpServer.init(8080);
    defer httpServer.deinit();
    try httpServer.route("/", rootHandler);
    try httpServer.run();
}
