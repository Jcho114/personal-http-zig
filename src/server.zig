const std = @import("std");
const http = @import("http.zig");

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

    fn handleConnection(_: *HttpServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();
        var buffer: [1000]u8 = undefined;
        for (0..buffer.len) |i| {
            buffer[i] = 0;
        }
        const size = try conn.stream.read(&buffer);
        var request = try http.Request.parse(buffer[0..size]);
        std.debug.print("{}\n", .{request});
        const hardcoded: []const u8 =
            \\HTTP/1.1 201 Created
            \\Content-Type: application/json
            \\Location: http://example.com/users/123
            \\
            \\testbody
        ;
        const response: []u8 = try std.heap.page_allocator.alloc(u8, hardcoded.len);
        @memcpy(response, hardcoded);
        _ = try conn.stream.write(response);
        defer request.deinit();
    }
};
