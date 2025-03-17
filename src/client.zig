const std = @import("std");
const http = @import("http.zig");

pub fn main() !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    var stream = try std.net.tcpConnectToAddress(address);
    const hardcoded: []const u8 =
        \\POST / HTTP/1.1
        \\Host: localhost:8080
        \\User-Agent: curl/8.7.1
        \\Accept: */*"
        \\
        \\testbody
    ;
    const request: []u8 = try std.heap.page_allocator.alloc(u8, hardcoded.len);
    @memcpy(request, hardcoded);
    _ = try stream.write(request);
    var buffer: [1000]u8 = undefined;
    for (0..buffer.len) |i| {
        buffer[i] = 0;
    }
    const size = try stream.read(&buffer);
    var response = try http.Response.parse(buffer[0..size]);
    defer response.deinit();
    std.debug.print("{}\n", .{response});
}
