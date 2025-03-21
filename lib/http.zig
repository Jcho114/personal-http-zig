const std = @import("std");
const buffers = @import("buffers.zig");
const requests = @import("requests.zig");
const responses = @import("responses.zig");

pub const Request = requests.Request;
pub const Response = responses.Response;
const statusCodeToText = responses.statusCodeToText;

pub const Method = enum { GET, POST, PUT, DELETE };

pub const Headers = std.hash_map.StringHashMap([]const u8);

pub const HttpClient = struct {
    pub const HttpClientOptions = struct {
        allocator: std.mem.Allocator,
        numBuffers: u16 = 1,
        bufferSize: u16 = 1000,
    };

    allocator: std.mem.Allocator,
    bufferPool: *buffers.BufferPool,

    pub fn init(options: HttpClientOptions) !*HttpClient {
        const httpClient = try options.allocator.create(HttpClient);
        const bufferPool = try buffers.BufferPool.init(.{
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

pub const HttpServer = struct {
    pub const HttpServerOptions = struct {
        allocator: std.mem.Allocator,
        port: u16 = 8080,
        numWorkers: u16 = 16,
        numBuffers: u16 = 16,
        bufferSize: u16 = 1000,
    };

    allocator: std.mem.Allocator,
    server: std.net.Server,
    routes: *Routes,
    numWorkers: u16,
    bufferPool: *buffers.BufferPool,

    pub fn init(options: HttpServerOptions) !*HttpServer {
        if (options.numWorkers == 0) {
            std.debug.print("numWorkers cannot be zero\n", .{});
            return error.InvalidOptions;
        }
        if (options.numWorkers > options.numBuffers) {
            std.debug.print("numWorkers is greater than numBuffers\n", .{});
            return error.InvalidOptions;
        }

        const bufferPool = try buffers.BufferPool.init(.{
            .allocator = options.allocator,
            .numBuffers = options.numBuffers,
            .bufferSize = options.bufferSize,
        });
        std.debug.print("buffer pool initialized with {} buffers\n", .{options.numBuffers});

        const address = try std.net.Address.parseIp4("127.0.0.1", options.port);
        const server = try address.listen(.{});
        const routes = try Routes.init(options.allocator);

        const httpServer = try options.allocator.create(HttpServer);
        httpServer.* = .{
            .allocator = options.allocator,
            .server = server,
            .routes = routes,
            .numWorkers = options.numWorkers,
            .bufferPool = bufferPool,
        };
        std.debug.print("server initiailized on port {d}\n", .{options.port});
        return httpServer;
    }

    pub fn deinit(self: *HttpServer) void {
        self.server.deinit();
        self.routes.deinit();
        self.bufferPool.deinit();
        self.allocator.destroy(self);
        std.debug.print("server now deinitialized\n", .{});
    }

    pub fn run(self: *HttpServer) !void {
        var wg = std.Thread.WaitGroup{};
        wg.reset();

        const threads = try self.allocator.alloc(std.Thread, self.numWorkers);
        defer self.allocator.free(threads);

        for (threads, 0..) |*thread, i| {
            wg.start();
            thread.* = try std.Thread.spawn(.{}, worker, .{ self, &wg });
            std.debug.print("worker #{d} spawned successfully\n", .{i + 1});
        }

        std.debug.print("server now listening for requests\n", .{});

        wg.wait();

        for (threads, 0..) |thread, i| {
            thread.join();
            std.debug.print("worker #{d} joined successfully\n", .{i + 1});
        }
    }

    pub fn worker(self: *HttpServer, wg: *std.Thread.WaitGroup) !void {
        while (true) {
            try self.process();
        }
        wg.finish();
    }

    pub fn process(self: *HttpServer) !void {
        const conn = try self.server.accept();
        self.handleConnectionWrapper(conn);
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

        const methodString = std.enums.tagName(Method, request.method) orelse std.debug.panic("unable to parse method to string...", .{});
        const target = try std.mem.concat(self.allocator, u8, &[_][]const u8{ methodString, " ", request.target });
        defer self.allocator.free(target);

        const handler = self.routes.get(target) orelse self.routes.get(request.target) orelse defaultHandler;

        const response = try Response.init(self.allocator);
        defer response.deinit();
        try handler(request, response);

        const statusText = try statusCodeToText(response.statusCode);
        std.debug.print("[Thread {d}] \"{s} {s} {s}\" {} {s}\n", .{
            thread_id,
            methodString,
            request.target,
            request.protocol,
            response.statusCode,
            statusText,
        });

        const formatted = try std.fmt.bufPrint(buffer, "{}", .{response});
        try conn.stream.writeAll(formatted);
        std.debug.print("[Thread {d}] finished sending response\n", .{thread_id});
    }

    pub fn route(self: *HttpServer, target: []const u8, handler: Handler) !void {
        var it = std.mem.splitSequence(u8, target, " ");
        const first = it.next() orelse "";
        if (it.rest().len != 0 and std.meta.stringToEnum(Method, first) == null) {
            std.debug.print("invalid route: \"{s}\"\n", .{target});
            return error.InvalidRoute;
        }

        if (self.routes.get(target) != null) {
            std.debug.print("duplicate route: \"{s}\"\n", .{target});
            return error.DuplicateRoute;
        }

        try self.routes.put(target, handler);
        std.debug.print("registered route: \"{s}\"\n", .{target});
    }
};

fn readHttp(buffer: []u8, stream: std.net.Stream) !usize {
    var totalRead: usize = 0;
    while (true) {
        const bytesRead = try stream.read(buffer[totalRead..]);
        if (bytesRead == 0) break;
        totalRead += bytesRead;
        if (totalRead >= buffer.len) {
            std.debug.print("buffer too small for response\n", .{});
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
            std.debug.print("buffer too small for response\n", .{});
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
    response.status(404);
}
