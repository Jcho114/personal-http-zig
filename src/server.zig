const std = @import("std");

pub fn main() !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    var server = try address.listen(.{});
    defer server.deinit();
    while (true) {
        try handleConnection(try server.accept());
    }
}

pub fn handleConnection(conn: std.net.Server.Connection) !void {
    defer conn.stream.close();
    var buffer: [1000]u8 = undefined;
    for (0..buffer.len) |i| {
        buffer[i] = 0;
    }
    const numBytes = try conn.stream.read(&buffer);
    var request = try Request.parse(buffer[0..numBytes]);
    defer request.deinit();
    std.debug.print("Target: {s}\n", .{request.target});
    std.debug.print("Host: {s}\n", .{request.headers.get("Host") orelse "null"});
    std.debug.print("Body: {s}\n", .{request.body});
}

const Method = enum { GET, POST, PUT, DELETE };

const Headers = std.StringHashMap([]const u8);

const Request = struct {
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
            if (header.len == 1) break;
            var headerIt = std.mem.splitSequence(u8, header, ": ");
            const key = headerIt.next() orelse return error.SomeError;
            const value = headerIt.rest();
            try headers.put(key, value);
        }

        const body = it.rest();

        const request: Request = .{ .method = method, .target = target, .protocol = protocol, .headers = headers, .body = body };
        return request;
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }
};
