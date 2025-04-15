const std = @import("std");
const http = @import("http.zig");

const Handler = http.Handler;
const Request = http.Request;
const Response = http.Response;

const StaticHandlerEdge = struct {
    value: []const u8,
    next: *HandlerNode,
};

const ParamHandlerEdge = struct {
    param: []const u8,
    next: *HandlerNode,
};

const HandlerNode = struct {
    const StaticHandlerEdgeMap = std.AutoHashMap(u8, StaticHandlerEdge);

    staticChildren: StaticHandlerEdgeMap,
    paramChild: ?ParamHandlerEdge,
    handler: ?*const Handler,

    pub fn init(allocator: std.mem.Allocator) !*HandlerNode {
        const node = try allocator.create(HandlerNode);
        node.* = .{
            .staticChildren = StaticHandlerEdgeMap.init(allocator),
            .paramChild = null,
            .handler = null,
        };
        return node;
    }

    pub fn deinit(self: *HandlerNode, allocator: std.mem.Allocator) void {
        var staticIt = self.staticChildren.valueIterator();
        while (staticIt.next()) |edge| edge.next.*.deinit(allocator);
        self.staticChildren.deinit();
        if (self.paramChild) |edge| {
            edge.next.*.deinit(allocator);
        }
        allocator.destroy(self);
    }
};

fn prefixCount(a: []const u8, b: []const u8) usize {
    var i: usize = 0;
    while (i < a.len and i < b.len and a[i] == b[i]) {
        i += 1;
    }
    return i;
}

pub const HandlerRadixTree = struct {
    allocator: std.mem.Allocator,
    root: *HandlerNode,

    pub fn init(allocator: std.mem.Allocator) !*HandlerRadixTree {
        const trie = try allocator.create(HandlerRadixTree);
        trie.* = .{
            .allocator = allocator,
            .root = try HandlerNode.init(allocator),
        };
        return trie;
    }

    pub fn insert(self: *HandlerRadixTree, key: []const u8, handler: *const Handler) !void {
        if (key.len == 0) {
            return error.InvalidKey;
        }

        var curr = self.root;
        var prefix = key;

        while (prefix.len > 0) {
            const isParam = prefix[0] == ':';
            if (isParam) {
                prefix = prefix[1..];
                var param: []const u8 = "";
                if (std.mem.indexOf(u8, prefix, "/")) |index| {
                    param = prefix[0..index];
                    prefix = prefix[index + 1 ..];
                } else {
                    param = prefix[0..];
                    prefix = "";
                }
                const new = try HandlerNode.init(self.allocator);
                new.handler = handler;
                curr.paramChild = .{
                    .param = param,
                    .next = new,
                };
                if (prefix.len == 0) {
                    return;
                }
                curr = new;
                continue;
            }

            const staticFound = curr.staticChildren.get(prefix[0]);
            if (staticFound) |edge| {
                const common = prefixCount(edge.value, prefix);
                if (common == edge.value.len and common == prefix.len) {
                    edge.next.handler = handler;
                    return;
                } else if (common == edge.value.len and common < prefix.len) {
                    curr = edge.next;
                    prefix = prefix[common..];
                } else {
                    const split = try HandlerNode.init(self.allocator);
                    try split.staticChildren.put(edge.value[common], .{
                        .value = edge.value[common..],
                        .next = edge.next,
                    });
                    if (prefix.len == common) {
                        split.handler = handler;
                    } else {
                        const new = try HandlerNode.init(self.allocator);
                        new.handler = handler;
                        try split.staticChildren.put(prefix[0], .{
                            .value = prefix[common..],
                            .next = new,
                        });
                    }
                    try curr.staticChildren.put(prefix[0], .{
                        .value = prefix[0..common],
                        .next = split,
                    });
                    return;
                }
            } else {
                const new = try HandlerNode.init(self.allocator);
                new.handler = handler;
                try curr.staticChildren.put(prefix[0], .{
                    .value = prefix,
                    .next = new,
                });
                return;
            }
        }
    }

    pub fn handle(self: HandlerRadixTree, key: []const u8, request: *Request, response: *Response) !void {
        if (key.len == 0) {
            return error.InvalidKey;
        }

        var curr = self.root;
        var prefix = key;

        while (prefix.len > 0) {
            const staticFound = curr.staticChildren.get(prefix[0]);
            if (staticFound) |edge| {
                const common = prefixCount(edge.value, prefix);
                if (common == edge.value.len and common == prefix.len) {
                    if (edge.next.handler) |handler| {
                        try handler(request, response);
                        return;
                    }
                    return error.HandlerNotFound;
                } else if (common == edge.value.len and common < prefix.len) {
                    curr = edge.next;
                    prefix = prefix[common..];
                    continue;
                } else {
                    return error.HandlerNotFound;
                }
            }

            if (curr.paramChild) |edge| {
                if (std.mem.indexOf(u8, prefix, "/")) |index| {
                    try request.params.put(edge.param, prefix[0..index]);
                    prefix = prefix[index + 1 ..];
                } else {
                    try request.params.put(edge.param, prefix[0..]);
                    prefix = "";
                }
                curr = edge.next;
                if (prefix.len == 0) {
                    if (curr.handler) |handler| {
                        try handler(request, response);
                        return;
                    }
                    return error.HandlerNotFound;
                }
            } else {
                return error.HandlerNotFound;
            }
        }

        return error.HandlerNotFound;
    }

    pub fn lookup(self: HandlerRadixTree, key: []const u8) !?*const Handler {
        if (key.len == 0) {
            return error.InvalidKey;
        }

        var curr = self.root;
        var prefix = key;

        while (prefix.len > 0) {
            const staticFound = curr.staticChildren.get(prefix[0]);
            if (staticFound) |edge| {
                const common = prefixCount(edge.value, prefix);
                if (common == edge.value.len and common == prefix.len) {
                    return edge.next.handler;
                } else if (common == edge.value.len and common < prefix.len) {
                    curr = edge.next;
                    prefix = prefix[common..];
                    continue;
                } else {
                    return null;
                }
            }

            if (curr.paramChild) |edge| {
                if (std.mem.indexOf(u8, prefix, "/")) |index| {
                    prefix = prefix[index + 1 ..];
                } else {
                    prefix = "";
                }
                curr = edge.next;
                if (prefix.len == 0) {
                    return curr.handler;
                }
            } else {
                return null;
            }
        }

        return null;
    }

    pub fn deinit(self: *HandlerRadixTree) void {
        self.root.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn testHandler(request: *http.Request, response: *http.Response) !void {
    response.status(200);
    response.send(request.target);
}

fn paramHandler(request: *http.Request, response: *http.Response) !void {
    response.status(200);
    response.send(request.target);
}

test {
    const expect = std.testing.expect;
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const trie = try HandlerRadixTree.init(allocator);
    defer trie.deinit();

    try trie.insert("/test", testHandler);
    try trie.insert("/", testHandler);
    try trie.insert("/:param/test", paramHandler);

    try expect(try trie.lookup("/") == &testHandler);
    try expect(try trie.lookup("/param/dne") == null);
    try expect(try trie.lookup("/param/test") == &paramHandler);
    try expect(try trie.lookup("/test") == &testHandler);
}
