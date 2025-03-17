const std = @import("std");

pub const HttpClient = struct {
    address: std.net.Address,
    buffer: [1000]u8 = undefined,

    pub fn init(host: []const u8, port: u16) !*HttpClient {
        const address = try std.net.Address.parseIp4(host, port);
        const httpClient = try std.heap.page_allocator.create(HttpClient);
        httpClient.* = .{ .address = address };
        return httpClient;
    }

    pub fn send(self: *HttpClient, request: *Request) !*Response {
        var stream = try std.net.tcpConnectToAddress(self.address);
        const formatted = try std.fmt.bufPrint(&self.buffer, "{}", .{request});
        _ = try stream.writeAll(formatted);

        const totalRead = try readHttp(&self.buffer, stream);

        const response = try Response.parse(self.buffer[0..totalRead]);
        return response;
    }

    pub fn deinit(self: *HttpClient) void {
        std.heap.page_allocator.destroy(self);
    }
};

const Handler = fn (*Request, *Response) anyerror!void;
const Routes = std.StringHashMap(*const Handler);

pub const HttpServer = struct {
    server: std.net.Server,
    routes: Routes,
    buffer: [1000]u8 = undefined,

    pub fn init(port: u16) !*HttpServer {
        const address = try std.net.Address.parseIp4("127.0.0.1", port);
        const server = try address.listen(.{});
        const httpServer = try std.heap.page_allocator.create(HttpServer);
        httpServer.* = .{ .server = server, .routes = Routes.init(std.heap.page_allocator) };
        return httpServer;
    }

    pub fn deinit(self: *HttpServer) void {
        self.server.deinit();
        self.routes.deinit();
        std.heap.page_allocator.destroy(self);
    }

    pub fn run(self: *HttpServer) !void {
        while (true) {
            const conn = try self.server.accept();
            try self.handleConnection(conn);
        }
    }

    fn handleConnection(self: *HttpServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();
        const totalRead = try readHttp(&self.buffer, conn.stream);
        var request = try Request.parse(self.buffer[0..totalRead]);
        defer request.deinit();
        std.debug.print("Request\n{}\n\n", .{request});

        const methodString = std.enums.tagName(Method, request.method) orelse std.debug.panic("unable to parse method to string...", .{});
        const target = try std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{ methodString, " ", request.target });
        defer std.heap.page_allocator.free(target);
        const handler = self.routes.get(target) orelse self.routes.get(request.target) orelse defaultHandler;
        const response = try Response.init();
        defer response.deinit();
        try handler(request, response);
        std.debug.print("Response\n{}\n\n", .{response});

        const formatted = try std.fmt.bufPrint(&self.buffer, "{}", .{response});
        _ = try conn.stream.writeAll(formatted);
    }

    pub fn route(self: *HttpServer, target: []const u8, handler: Handler) !void {
        var it = std.mem.splitSequence(u8, target, " ");
        const first = it.next() orelse "";
        if (it.rest().len != 0 and std.meta.stringToEnum(Method, first) == null) {
            return error.SomeError;
        }
        try self.routes.put(target, handler);
    }
};

fn readHttp(buffer: []u8, stream: std.net.Stream) !usize {
    var totalRead: usize = 0;
    while (true) {
        const bytesRead = try stream.read(buffer[totalRead..]);
        if (bytesRead == 0) break;
        totalRead += bytesRead;
        if (totalRead >= buffer.len) {
            std.debug.print("Buffer too small for response\n", .{});
            break;
        }
        if (std.mem.count(u8, buffer[0..totalRead], "\r\n\r\n") == 1) {
            break;
        }
    }

    const headerEnd = std.mem.indexOf(u8, buffer[0..totalRead], "\r\n\r\n") orelse return totalRead;
    const headers = buffer[0..headerEnd];
    var bodyLen: usize = 0;
    var headerIter = std.mem.splitSequence(u8, headers, "\r\n");

    while (headerIter.next()) |line| {
        if (std.mem.startsWith(u8, line, "Content-Length: ")) {
            const lengthStr = std.mem.trimLeft(u8, line[16..], " ");
            bodyLen = try std.fmt.parseInt(usize, lengthStr, 10);
            break;
        }
    }

    const bodyStart = headerEnd + 4;
    const alreadyReadBody = if (totalRead > bodyStart) totalRead - bodyStart else 0;

    var bodyRead = alreadyReadBody;
    while (bodyRead < bodyLen) {
        if (bodyRead >= bodyLen) {
            break;
        }

        if (totalRead >= buffer.len) {
            std.debug.print("Buffer too small for response\n", .{});
            break;
        }

        const bytesRead = try stream.read(buffer[totalRead..]);
        if (bytesRead == 0) break;
        bodyRead += bytesRead;
        totalRead += bytesRead;
    }

    return totalRead;
}

fn defaultHandler(_: *Request, response: *Response) !void {
    response.* = .{
        .statusCode = 404,
        .statusText = "Not Found",
    };
}

pub const Method = enum { GET, POST, PUT, DELETE };

pub const Headers = std.StringHashMap([]const u8);

pub const Request = struct {
    method: Method,
    target: []const u8,
    protocol: []const u8 = "HTTP/1.1",
    headers: Headers = Headers.init(std.heap.page_allocator),
    body: []const u8 = "",

    pub fn init() !*Request {
        const request = try std.heap.page_allocator.create(Request);
        return request;
    }

    pub fn parse(stream: []u8) !*Request {
        var it = std.mem.splitSequence(u8, stream, "\r\n");
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

        const request = try std.heap.page_allocator.create(Request);
        request.* = .{ .method = method, .target = target, .protocol = protocol, .headers = headers, .body = body };
        return request;
    }

    pub fn format(self: Request, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const methodString = std.enums.tagName(Method, self.method) orelse std.debug.panic("unable to parse method to string...", .{});
        try writer.print("{s} {s} {s}\r\n", .{ methodString, self.target, self.protocol });
        var it = self.headers.iterator();
        while (it.next()) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.key_ptr.*, header.value_ptr.* });
        }
        try writer.writeAll("\r\n");
        try writer.writeAll(self.body);
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

pub const Response = struct {
    protocol: []const u8 = "HTTP/1.1",
    statusCode: u16,
    statusText: []const u8,
    headers: Headers = Headers.init(std.heap.page_allocator),
    body: []const u8 = "",

    pub fn init() !*Response {
        const response = try std.heap.page_allocator.create(Response);
        return response;
    }

    pub fn parse(stream: []u8) !*Response {
        var it = std.mem.splitSequence(u8, stream, "\r\n");
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

        if (headers.get("Content-Length") == null) {
            try headers.put("Content-Length", std.mem.asBytes(&body.len));
        }

        const response = try std.heap.page_allocator.create(Response);
        response.* = .{ .protocol = protocol, .statusCode = statusCode, .statusText = statusText, .headers = headers, .body = body };
        return response;
    }

    pub fn format(self: Response, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s} {} {s}\r\n", .{ self.protocol, self.statusCode, self.statusText });
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

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        std.heap.page_allocator.destroy(self);
    }
};
