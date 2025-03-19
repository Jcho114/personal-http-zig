const std = @import("std");

const BufferPoolOptions = struct {
    allocator: std.mem.Allocator,
    numBuffers: u16,
    bufferSize: u16,
};

const Queue = std.DoublyLinkedList(u8);
const Buffer = []u8;
const Buffers = std.ArrayList(Buffer);

const BufferPool = struct {
    allocator: std.mem.Allocator,
    buffers: Buffers,
    queue: Queue,
    mutex: std.Thread.Mutex,

    pub fn init(options: BufferPoolOptions) !*BufferPool {
        const bufferPool = try options.allocator.create(BufferPool);
        var buffers = Buffers.init(options.allocator);
        var queue = Queue{};
        const mutex = std.Thread.Mutex{};
        for (0..options.numBuffers) |i| {
            const node = try options.allocator.create(Queue.Node);
            node.data = @intCast(i);
            queue.append(node);
            const buffer = try options.allocator.alloc(u8, options.bufferSize);
            try buffers.append(buffer);
        }
        bufferPool.* = .{
            .allocator = options.allocator,
            .buffers = buffers,
            .queue = queue,
            .mutex = mutex,
        };
        return bufferPool;
    }

    pub fn get(self: *BufferPool) !*Buffer {
        self.mutex.lock();
        defer self.mutex.unlock();
        const node = self.queue.pop() orelse return error.BufferUnavailable;
        defer self.allocator.destroy(node);
        return &self.buffers.items[node.data];
    }

    pub fn release(self: *BufferPool, buffer: *Buffer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var idx: u8 = 0;
        for (self.buffers.items, 0..) |*b, i| {
            if (b == buffer) {
                idx = @intCast(i);
                break;
            }
        }
        const node = try self.allocator.create(Queue.Node);
        node.data = idx;
        self.queue.prepend(node);
    }

    pub fn deinit(self: *BufferPool) void {
        for (self.buffers.items) |b| {
            self.allocator.free(b);
        }
        self.buffers.deinit();
        while (self.queue.pop()) |node| {
            self.allocator.destroy(node);
        }
        self.allocator.destroy(self);
    }
};

pub const HttpClientOptions = struct {
    allocator: std.mem.Allocator,
    numBuffers: u16 = 1,
    bufferSize: u16 = 1000,
};

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    bufferPool: *BufferPool,

    pub fn init(options: HttpClientOptions) !*HttpClient {
        const httpClient = try options.allocator.create(HttpClient);
        const bufferPool = try BufferPool.init(.{
            .allocator = options.allocator,
            .numBuffers = options.numBuffers,
            .bufferSize = options.bufferSize,
        });
        std.debug.print("initialized buffer pool with {} buffers\n", .{options.numBuffers});
        httpClient.* = .{
            .allocator = options.allocator,
            .bufferPool = bufferPool,
        };
        std.debug.print("initialized http client\n", .{});
        return httpClient;
    }

    pub fn send(self: *HttpClient, host: []const u8, port: u16, request: *Request) !*Response {
        const bufferPointer = try self.bufferPool.get();
        defer {
            self.bufferPool.release(bufferPointer) catch |err| {
                std.debug.print("error releasing buffer: {}\n", .{err});
            };
        }

        const buffer = bufferPointer.*;
        const address = try std.net.Address.parseIp4(host, port);
        var stream = try std.net.tcpConnectToAddress(address);

        const formatted = try std.fmt.bufPrint(buffer, "{}", .{request});
        std.debug.print("sending request to {s}\n", .{host});
        try stream.writeAll(formatted);

        const totalRead = try readHttp(buffer, stream);
        std.debug.print("received response from {s}\n", .{host});

        const response = try Response.parse(buffer[0..totalRead], self.allocator);
        return response;
    }

    pub fn deinit(self: *HttpClient) void {
        self.bufferPool.deinit();
        self.allocator.destroy(self);
    }
};

const Handler = fn (*Request, *Response) anyerror!void;

const Routes = struct {
    allocator: std.mem.Allocator,
    map: std.hash_map.StringHashMap(*const Handler),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !*Routes {
        const routes = try allocator.create(Routes);
        const map = std.hash_map.StringHashMap(*const Handler).init(allocator);
        const mutex = std.Thread.Mutex{};
        routes.* = .{
            .allocator = allocator,
            .map = map,
            .mutex = mutex,
        };
        return routes;
    }

    pub fn deinit(self: *Routes) void {
        self.map.deinit();
        self.allocator.destroy(self);
    }

    pub fn get(self: *Routes, key: []const u8) ?*const Handler {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(key);
    }

    pub fn put(self: *Routes, key: []const u8, handler: *const Handler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try self.map.put(key, handler);
    }
};

pub const HttpServerOptions = struct {
    allocator: std.mem.Allocator,
    port: u16 = 8080,
    numWorkers: u16 = 16,
    numBuffers: u16 = 16,
    bufferSize: u16 = 1000,
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    server: std.net.Server,
    routes: *Routes,
    threadPool: std.Thread.Pool,
    bufferPool: *BufferPool,

    pub fn init(options: HttpServerOptions) !*HttpServer {
        if (options.numWorkers == 0) {
            std.debug.print("numWorkers cannot be zero\n", .{});
            return error.InvalidOptions;
        }
        if (options.numWorkers > options.numBuffers) {
            std.debug.print("numWorkers is greater than numBuffers\n", .{});
            return error.InvalidOptions;
        }

        var threadPool: std.Thread.Pool = undefined;
        try threadPool.init(std.Thread.Pool.Options{
            .allocator = options.allocator,
            .n_jobs = options.numWorkers,
        });
        std.debug.print("thread pool initialized with {} workers\n", .{options.numWorkers});
        const bufferPool = try BufferPool.init(.{
            .allocator = options.allocator,
            .numBuffers = options.numBuffers,
            .bufferSize = options.bufferSize,
        });
        std.debug.print("buffer pool initialized with {} buffers\n", .{options.numBuffers});

        const httpServer = try options.allocator.create(HttpServer);
        const address = try std.net.Address.parseIp4("127.0.0.1", options.port);
        const server = try address.listen(.{});
        const routes = try Routes.init(options.allocator);

        httpServer.* = .{
            .allocator = options.allocator,
            .server = server,
            .routes = routes,
            .threadPool = threadPool,
            .bufferPool = bufferPool,
        };
        std.debug.print("server initiailized on port {d}\n", .{options.port});
        return httpServer;
    }

    pub fn deinit(self: *HttpServer) void {
        self.server.deinit();
        self.routes.deinit();
        self.threadPool.deinit();
        self.bufferPool.deinit();
        self.allocator.destroy(self);
        std.debug.print("server now deinitialized\n", .{});
    }

    pub fn run(self: *HttpServer) !void {
        std.debug.print("server now listening for requests\n", .{});
        while (true) {
            const conn = self.server.accept() catch |err| {
                std.debug.print("failed to accept connection: {}\n", .{err});
                continue;
            };
            _ = try std.Thread.spawn(.{}, handleConnectionWrapper, .{ self, conn });
            errdefer conn.stream.close();
            std.debug.print("thread spawned for connection\n", .{});
        }
    }

    pub fn handleConnectionWrapper(self: *HttpServer, conn: std.net.Server.Connection) void {
        const thread_id = std.Thread.getCurrentId();
        std.debug.print("[Thread {d}] conn handling started\n", .{thread_id});
        defer {
            conn.stream.close();
            std.debug.print("[Thread {d}] conn closed\n", .{thread_id});
        }
        const start = std.time.milliTimestamp();
        self.handleConnection(conn) catch |err| {
            std.debug.print("[Thread {d}] conn handling error: {}\n", .{ thread_id, err });
        };
        const end = std.time.milliTimestamp();
        std.debug.print("[Thread {d}] processed request in {d} ms\n", .{ thread_id, end - start });
    }

    fn handleConnection(self: *HttpServer, conn: std.net.Server.Connection) !void {
        const thread_id = std.Thread.getCurrentId();
        std.debug.print("[Thread {d}] handling conn\n", .{thread_id});
        const bufferPointer = try self.bufferPool.get();
        defer {
            self.bufferPool.release(bufferPointer) catch |err| {
                std.debug.print("[Thread {d}] error releasing buffer: {}\n", .{ thread_id, err });
            };
        }

        const buffer = bufferPointer.*;
        const totalRead = try readHttp(buffer, conn.stream);
        if (totalRead == 0) return;

        var request = try Request.parse(buffer[0..totalRead], self.allocator);
        defer request.deinit();
        std.debug.print("[Thread {d}] request\n{}\n\n", .{ thread_id, request });

        const methodString = std.enums.tagName(Method, request.method) orelse std.debug.panic("unable to parse method to string...", .{});
        const target = try std.mem.concat(self.allocator, u8, &[_][]const u8{ methodString, " ", request.target });
        defer self.allocator.free(target);

        const handler = self.routes.get(target) orelse self.routes.get(request.target) orelse defaultHandler;

        const response = try Response.init(self.allocator);
        defer response.deinit();
        try handler(request, response);
        std.debug.print("[Thread {d}] response\n{}\n\n", .{ thread_id, response });

        const formatted = try std.fmt.bufPrint(buffer, "{}", .{response});
        try conn.stream.writeAll(formatted);
        std.debug.print("[Thread {d}] finished sending response\n", .{thread_id});
    }

    pub fn route(self: *HttpServer, target: []const u8, handler: Handler) !void {
        var it = std.mem.splitSequence(u8, target, " ");
        const first = it.next() orelse "";
        if (it.rest().len != 0 and std.meta.stringToEnum(Method, first) == null) {
            std.debug.print("invalid route: '{s}'\n", .{target});
            return error.InvalidRoute;
        }

        if (self.routes.get(target) != null) {
            std.debug.print("duplicate route: '{s}'\n", .{target});
            return error.DuplicateRoute;
        }

        try self.routes.put(target, handler);
        std.debug.print("registered route: '{s}'\n", .{target});
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
    response.statusCode = 404;
    response.statusText = "Not Found";
}

pub const Method = enum { GET, POST, PUT, DELETE };

pub const Headers = std.hash_map.StringHashMap([]const u8);

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: Method,
    target: []const u8,
    protocol: []const u8,
    headers: Headers,
    body: []const u8,

    pub fn init(allocator: std.mem.Allocator) !*Request {
        const request = try allocator.create(Request);
        request.* = .{
            .allocator = allocator,
            .method = Method.GET,
            .target = "/",
            .protocol = "HTTP/1.1",
            .headers = Headers.init(allocator),
            .body = "",
        };
        return request;
    }

    pub fn parse(stream: []u8, allocator: std.mem.Allocator) !*Request {
        var it = std.mem.splitSequence(u8, stream, "\r\n");
        const firstLine = it.next() orelse return error.ParseError;
        var firstLineIt = std.mem.splitSequence(u8, firstLine, " ");
        const methodString = firstLineIt.next() orelse return error.ParseError;
        const method = std.meta.stringToEnum(Method, methodString) orelse return error.ParseError;
        const target = firstLineIt.next() orelse return error.ParseError;
        const protocol = firstLineIt.next() orelse return error.ParseError;

        var headers = Headers.init(allocator);
        while (it.next()) |header| {
            if (std.mem.trim(u8, header, " \r\n").len == 0) break;
            var headerIt = std.mem.splitSequence(u8, header, ": ");
            const key = headerIt.next() orelse return error.ParseError;
            const value = headerIt.rest();
            try headers.put(key, value);
        }

        const body = it.rest();

        const request = try allocator.create(Request);
        request.* = .{
            .allocator = allocator,
            .method = method,
            .target = target,
            .protocol = protocol,
            .headers = headers,
            .body = body,
        };
        return request;
    }

    pub fn format(self: *Request, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
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
        self.allocator.destroy(self);
    }
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    protocol: []const u8 = "HTTP/1.1",
    statusCode: u16,
    statusText: []const u8,
    headers: Headers,
    body: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) !*Response {
        const response = try allocator.create(Response);
        response.allocator = allocator;
        response.headers = Headers.init(allocator);
        response.* = .{
            .allocator = allocator,
            .protocol = "HTTP/1.1",
            .statusCode = 200,
            .statusText = "Ok",
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
        const statusText = firstLineIt.next() orelse return error.ParseError;

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
            .statusText = statusText,
            .headers = headers,
            .body = body,
        };
        return response;
    }

    pub fn format(self: *Response, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
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
        self.allocator.destroy(self);
    }
};
