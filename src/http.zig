const std = @import("std");

pub const Method = enum { GET, POST, PUT, DELETE };

pub const Headers = std.StringHashMap([]const u8);

pub const Request = struct {
    method: Method,
    target: []const u8,
    protocol: []const u8,
    headers: Headers,
    body: []const u8,

    pub fn parse(stream: []u8) !Request {
        var it = std.mem.splitSequence(u8, stream, "\n");
        const firstLine = it.next() orelse return error.SomeError;
        var firstLineIt = std.mem.splitSequence(u8, firstLine, " ");
        const methodString = firstLineIt.next() orelse return error.SomeError;
        const method = std.meta.stringToEnum(Method, methodString) orelse return error.SomeError;
        const target = firstLineIt.next() orelse return error.SomeError;
        const protocol = firstLineIt.next() orelse return error.SomeError;

        var headers = Headers.init(std.heap.page_allocator);
        while (it.next()) |header| {
            if (std.mem.trim(u8, header, " \r\n").len == 0) break;
            var headerIt = std.mem.splitSequence(u8, header, ": ");
            const key = headerIt.next() orelse return error.SomeError;
            const value = headerIt.rest();
            try headers.put(key, value);
        }

        const body = it.rest();

        const request: Request = .{ .method = method, .target = target, .protocol = protocol, .headers = headers, .body = body };
        return request;
    }

    pub fn format(self: Request, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const methodString = std.enums.tagName(Method, self.method) orelse std.debug.panic("unable to parse method to string...", .{});
        try writer.print("{s} {s} {s}\n", .{ methodString, self.target, self.protocol });
        var it = self.headers.iterator();
        while (it.next()) |header| {
            try writer.print("{s}: {s}\n", .{ header.key_ptr.*, header.value_ptr.* });
        }
        try writer.writeAll("\n");
        try writer.writeAll(self.body);
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }
};

pub const Response = struct {
    protocol: []const u8,
    statusCode: u16,
    statusText: []const u8,
    headers: Headers,
    body: []const u8,

    pub fn parse(stream: []u8) !Response {
        var it = std.mem.splitSequence(u8, stream, "\n");
        const firstLine = it.next() orelse return error.SomeError;
        var firstLineIt = std.mem.splitSequence(u8, firstLine, " ");
        const protocol = firstLineIt.next() orelse return error.SomeError;
        const statusCodeString = firstLineIt.next() orelse return error.SomeError;
        const statusCode = try std.fmt.parseInt(u16, statusCodeString, 10);
        const statusText = firstLineIt.next() orelse return error.SomeError;

        var headers = Headers.init(std.heap.page_allocator);
        while (it.next()) |header| {
            if (std.mem.trim(u8, header, " \r\n").len == 0) break;
            var headerIt = std.mem.splitSequence(u8, header, ": ");
            const key = headerIt.next() orelse return error.SomeError;
            const value = headerIt.rest();
            try headers.put(key, value);
        }

        const body = it.rest();

        const response: Response = .{ .protocol = protocol, .statusCode = statusCode, .statusText = statusText, .headers = headers, .body = body };
        return response;
    }

    pub fn format(self: Response, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s} {} {s}\n", .{ self.protocol, self.statusCode, self.statusText });
        var it = self.headers.iterator();
        while (it.next()) |header| {
            try writer.print("{s}: {s}\n", .{ header.key_ptr.*, header.value_ptr.* });
        }
        try writer.writeAll("\n");
        try writer.writeAll(self.body);
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
    }
};
