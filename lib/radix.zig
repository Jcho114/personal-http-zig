const std = @import("std");
const http = @import("http.zig");

const Handler = http.Handler;

const HandlerEdge = struct {
    value: []const u8,
    next: *HandlerNode,
};

const HandlerNode = struct {
    const HandlerEdgeMap = std.AutoHashMap(u8, HandlerEdge);

    children: HandlerEdgeMap,
    handler: ?*const Handler,

    pub fn init(allocator: std.mem.Allocator) !*HandlerNode {
        const node = try allocator.create(HandlerNode);
        node.* = .{
            .children = HandlerEdgeMap.init(allocator),
            .handler = null,
        };
        return node;
    }

    pub fn deinit(self: *HandlerNode, allocator: std.mem.Allocator) void {
        var it = self.children.valueIterator();
        while (it.next()) |edge| edge.next.*.deinit(allocator);
        self.children.deinit();
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
            const found = curr.children.get(prefix[0]);

            if (found) |edge| {
                const common = prefixCount(edge.value, prefix);
                if (common == edge.value.len and common == prefix.len) {
                    edge.next.handler = handler;
                    return;
                } else if (common == edge.value.len and common < prefix.len) {
                    curr = edge.next;
                    prefix = prefix[common..];
                } else {
                    const split = try HandlerNode.init(self.allocator);
                    try split.children.put(edge.value[common], .{
                        .value = edge.value[common..],
                        .next = edge.next,
                    });
                    if (prefix.len == common) {
                        split.handler = handler;
                    } else {
                        const new = try HandlerNode.init(self.allocator);
                        new.handler = handler;
                        try split.children.put(prefix[0], .{
                            .value = prefix[common..],
                            .next = new,
                        });
                    }
                    try curr.children.put(prefix[0], .{
                        .value = prefix[0..common],
                        .next = split,
                    });
                    return;
                }
            } else {
                const new = try HandlerNode.init(self.allocator);
                new.handler = handler;
                try curr.children.put(prefix[0], .{
                    .value = prefix,
                    .next = new,
                });
                return;
            }
        }
    }

    pub fn lookup(self: HandlerRadixTree, key: []const u8) !?*const Handler {
        if (key.len == 0) {
            return error.InvalidKey;
        }

        var curr = self.root;
        var prefix = key;

        while (prefix.len > 0) {
            const found = curr.children.get(prefix[0]);

            if (found) |edge| {
                const common = prefixCount(edge.value, prefix);

                if (common == edge.value.len and common == prefix.len) {
                    return edge.next.handler;
                } else if (common == edge.value.len and common < prefix.len) {
                    curr = edge.next;
                    prefix = prefix[common..];
                } else {
                    return null;
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

test {
    const expect = std.testing.expect;
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const trie = try HandlerRadixTree.init(allocator);
    defer trie.deinit();

    try trie.insert("/test", testHandler);
    try trie.insert("/", testHandler);
    try trie.insert("GET /", testHandler);

    try expect(try trie.lookup("/") == &testHandler);
    try expect(try trie.lookup("/test") == &testHandler);
    try expect(try trie.lookup("/teSt") == null);
    try expect(try trie.lookup("/dne") == null);
    try expect(try trie.lookup("GET /") == &testHandler);
}
