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
    _ = try conn.stream.read(&buffer);
    std.debug.print("{s}\n", .{buffer});
}
