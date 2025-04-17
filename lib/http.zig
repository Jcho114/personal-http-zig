const std = @import("std");

const buffers = @import("buffers.zig");
const radix = @import("radix.zig");
const HandlerRadixTree = radix.HandlerRadixTree;

const json = @import("json.zig");
pub const JsonArray = json.JsonArray;
pub const JsonObject = json.JsonObject;

const requests = @import("requests.zig");
const responses = @import("responses.zig");

pub const Request = requests.Request;
pub const Response = responses.Response;
const statusCodeToText = responses.statusCodeToText;

pub const Method = enum { GET, POST, PUT, DELETE };

pub const Headers = std.hash_map.StringHashMap([]const u8);

pub const Cookies = std.hash_map.StringHashMap([]const u8);

pub const Handler = fn (*Request, *Response) anyerror!void;

const Routes = struct {
    allocator: std.mem.Allocator,
    trie: *HandlerRadixTree,
    rwlock: std.Thread.RwLock,

    pub fn init(allocator: std.mem.Allocator) !*Routes {
        const routes = try allocator.create(Routes);
        const trie = try HandlerRadixTree.init(allocator);
        const rwlock = std.Thread.RwLock{};
        routes.* = .{
            .allocator = allocator,
            .trie = trie,
            .rwlock = rwlock,
        };
        return routes;
    }

    pub fn deinit(self: *Routes) void {
        self.trie.deinit();
        self.allocator.destroy(self);
    }

    pub fn handle(self: *Routes, key: []const u8, request: *Request, response: *Response) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();
        try self.trie.handle(key, request, response);
    }

    pub fn get(self: *Routes, key: []const u8) ?*const Handler {
        self.rwlock.lock();
        defer self.rwlock.unlock();
        return self.trie.lookup(key) catch null;
    }

    pub fn put(self: *Routes, key: []const u8, handler: *const Handler) !void {
        self.rwlock.lock();
        defer self.rwlock.unlock();
        return try self.trie.insert(key, handler);
    }
};

pub const HttpServer = struct {
    pub const HttpServerOptions = struct {
        allocator: std.mem.Allocator,
        port: u16,
        numWorkers: u16,
        numBuffers: u16,
        bufferSize: u16,

        pub fn default(allocator: std.mem.Allocator) !HttpServerOptions {
            const cores = try std.Thread.getCpuCount();
            return HttpServerOptions{
                .allocator = allocator,
                .port = 8080,
                .numWorkers = @intCast(cores),
                .numBuffers = @intCast(cores * 2),
                .bufferSize = 8192,
            };
        }
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
        if (2 * options.numWorkers > options.numBuffers) {
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
        defer wg.finish();
        const readBufferPointer = try self.bufferPool.get();
        const writeBufferPointer = try self.bufferPool.get();
        const thread_id = std.Thread.getCurrentId();
        defer {
            self.bufferPool.release(readBufferPointer) catch |err| {
                std.debug.print("[Thread {d}] error releasing read buffer: {}\n", .{ thread_id, err });
            };
            self.bufferPool.release(writeBufferPointer) catch |err| {
                std.debug.print("[Thread {d}] error releasing write buffer: {}\n", .{ thread_id, err });
            };
        }
        while (true) {
            self.process(readBufferPointer, writeBufferPointer) catch |err| {
                std.debug.print("[Thread {d}] error processing request: {}\n", .{ thread_id, err });
                continue;
            };
        }
    }

    pub fn process(self: *HttpServer, readBufferPointer: *[]u8, writeBufferPointer: *[]u8) !void {
        const conn = try self.server.accept();
        self.handleConnectionWrapper(conn, readBufferPointer, writeBufferPointer);
    }

    pub fn handleConnectionWrapper(self: *HttpServer, conn: std.net.Server.Connection, readBufferPointer: *[]u8, writeBufferPointer: *[]u8) void {
        const thread_id = std.Thread.getCurrentId();
        std.debug.print("[Thread {d}] conn handling started\n", .{thread_id});
        defer {
            conn.stream.close();
            std.debug.print("[Thread {d}] conn closed\n", .{thread_id});
        }
        const start = std.time.milliTimestamp();
        self.handleConnection(conn, readBufferPointer, writeBufferPointer) catch |err| {
            std.debug.print("[Thread {d}] conn handling error: {}\n", .{ thread_id, err });
        };
        const end = std.time.milliTimestamp();
        std.debug.print("[Thread {d}] processed request in {d} ms\n", .{ thread_id, end - start });
    }

    fn handleConnection(self: *HttpServer, conn: std.net.Server.Connection, readBufferPointer: *[]u8, writeBufferPointer: *[]u8) !void {
        const thread_id = std.Thread.getCurrentId();
        std.debug.print("[Thread {d}] handling conn\n", .{thread_id});

        const readBuffer = readBufferPointer.*;
        const writeBuffer = writeBufferPointer.*;
        const totalRead = try readHttp(readBuffer, conn.stream);
        if (totalRead == 0) return;

        var request = try Request.parse(readBuffer[0..totalRead], self.allocator);
        defer request.deinit();

        const methodString = std.enums.tagName(Method, request.method) orelse std.debug.panic("unable to parse method to string...", .{});
        const target = try std.mem.concat(self.allocator, u8, &[_][]const u8{ methodString, " ", request.target });
        defer self.allocator.free(target);

        const response = try Response.init(self.allocator);
        defer response.deinit();

        self.routes.handle(target, request, response) catch
            self.routes.handle(request.target, request, response) catch
            defaultHandler(request, response);

        const statusText = try statusCodeToText(response.statusCode);
        std.debug.print("[Thread {d}] \"{s} {s} {s}\" {} {s}\n", .{
            thread_id,
            methodString,
            request.target,
            request.protocol,
            response.statusCode,
            statusText,
        });

        const formatted = try std.fmt.bufPrint(writeBuffer, "{}", .{response});
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

fn defaultHandler(_: *Request, response: *Response) void {
    response.status(404);
}
