const std = @import("std");

pub fn main() !void {
    var httpServer = try HttpServer.init();
    defer httpServer.deinit();
    try httpServer.run();
}

const HttpServer = struct {
    server: std.net.Server,

    pub fn init() !HttpServer {
        const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
        const server = try address.listen(.{});
        const httpServer: HttpServer = .{ .server = server };
        return httpServer;
    }

    pub fn deinit(self: *HttpServer) void {
        self.server.deinit();
    }

    pub fn run(self: *HttpServer) !void {
        while (true) {
            const conn = try self.server.accept();
            try self.handleConnection(conn);
        }
    }

    pub fn handleConnection(_: *HttpServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();
        var buffer: [1000]u8 = undefined;
        for (0..buffer.len) |i| {
            buffer[i] = 0;
        }
        const numBytes = try conn.stream.read(&buffer);
        var request = try Request.parse(buffer[0..numBytes]);
        std.debug.print("{}\n", .{request});
        defer request.deinit();
    }
};

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
