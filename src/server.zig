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

pub fn testJsonEchoHandler(request: *http.Request, response: *http.Response) !void {
    const resobj = try JsonObject.init(response.allocator);
    defer resobj.deinit();

    const reqobj = JsonObject.parse(request.body, request.allocator) catch {
        try resobj.put(.string, "message", "no json provided");
        response.status(400);
        return try response.jsonObject(resobj);
    };

    const reqmes = reqobj.get(.string, "message") catch {
        try resobj.put(.string, "message", "request json has no field message");
        response.status(400);
        return try response.jsonObject(resobj);
    };

    try resobj.put(.string, "message", reqmes);
    response.status(200);
    try response.jsonObject(resobj);
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
    try httpServer.route("POST /test/json", testJsonEchoHandler);
    try httpServer.route("/:param/test", testParamHandler);

    try httpServer.run();
}
