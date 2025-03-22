const std = @import("std");
const http = @import("http.zig");

const Headers = http.Headers;

pub fn statusCodeToText(statusCode: u16) ![]const u8 {
    const statusText = switch (statusCode) {
        100 => "Continue",
        101 => "Switching Protocols",
        102 => "Processing",
        103 => "Early Hints",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        203 => "Non-Authoritative Information",
        204 => "No Content",
        205 => "Reset Content",
        206 => "Partial Content",
        207 => "Multi-Status",
        208 => "Already Reported",
        226 => "IM Used",
        300 => "Multiple Choices",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        305 => "Use Proxy",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        407 => "Proxy Authentication Required",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        418 => "I'm a teapot",
        421 => "Misdirected Request",
        422 => "Unprocessable Content",
        423 => "Locked",
        424 => "Failed Dependency",
        425 => "Too Early",
        426 => "Upgrade Required",
        428 => "Precondition Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        451 => "Unavailable For Legal Reasons",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Server Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        506 => "Variant Also Negotiates",
        507 => "Insufficient Storage",
        508 => "Loop Detected",
        510 => "Not Extended",
        511 => "Network Authentication Required",
        else => return error.InvalidStatusCode,
    };
    return statusText;
}

pub const Response = struct {
    allocator: std.mem.Allocator,
    protocol: []const u8,
    statusCode: u16,
    headers: Headers,
    body: []const u8,

    pub fn init(allocator: std.mem.Allocator) !*Response {
        const response = try allocator.create(Response);
        response.allocator = allocator;
        response.headers = Headers.init(allocator);
        response.* = .{
            .allocator = allocator,
            .protocol = "HTTP/1.1",
            .statusCode = 200,
            .headers = Headers.init(allocator),
            .body = "",
        };
        return response;
    }

    pub fn parse(stream: []u8, allocator: std.mem.Allocator) !*Response {
        var it = std.mem.splitSequence(u8, stream, "\r\n");
        const firstLine = it.next() orelse return error.ParseError;
        var firstLineIt = std.mem.splitSequence(u8, firstLine, " ");
        const protocol = firstLineIt.next() orelse return error.ParseError;
        const statusCodeString = firstLineIt.next() orelse return error.ParseError;
        const statusCode = try std.fmt.parseInt(u16, statusCodeString, 10);

        var headers = Headers.init(allocator);
        while (it.next()) |header| {
            if (std.mem.trim(u8, header, " \r\n").len == 0) break;
            var headerIt = std.mem.splitSequence(u8, header, ": ");
            const key = headerIt.next() orelse return error.ParseError;
            const value = headerIt.rest();
            try headers.put(key, value);
        }

        const body = it.rest();

        if (headers.get("Content-Length") == null) {
            try headers.put("Content-Length", std.mem.asBytes(&body.len));
        }

        const response = try allocator.create(Response);
        response.* = .{
            .allocator = allocator,
            .protocol = protocol,
            .statusCode = statusCode,
            .headers = headers,
            .body = body,
        };
        return response;
    }

    pub fn format(self: *Response, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const statusText = try statusCodeToText(self.statusCode);
        try writer.print("{s} {} {s}\r\n", .{ self.protocol, self.statusCode, statusText });
        var it = self.headers.iterator();
        while (it.next()) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.key_ptr.*, header.value_ptr.* });
        }
        if (self.headers.get("Content-Length") == null) {
            try writer.print("{s}: {}\r\n", .{ "Content-Length", self.body.len });
        }
        try writer.writeAll("\r\n");
        try writer.writeAll(self.body);
    }

    pub fn status(self: *Response, code: u16) void {
        self.statusCode = code;
    }

    pub fn send(self: *Response, content: []const u8) void {
        self.body = content;
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.allocator.destroy(self);
    }
};
