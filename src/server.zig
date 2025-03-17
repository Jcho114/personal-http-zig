const std = @import("std");
const http = @import("http");

pub fn rootHandler(request: *http.Request, response: *http.Response) !void {
    response.* = .{
        .statusCode = 200,
        .statusText = "Ok",
        .body = request.target,
    };
}

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
    try httpServer.route("/", rootHandler);
    try httpServer.route("GET /test", testGetHandler);
    try httpServer.run();
}
