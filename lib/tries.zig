const std = @import("std");
const http = @import("http.zig");

const Handler = http.Handler;

const HandlerEdge = struct {
    value: u8,
    next: *HandlerNode,
};

const HandlerNode = struct {
    const HandlerEdgeList = std.ArrayList(HandlerEdge);

    children: HandlerEdgeList,
    handler: ?*const Handler,

    pub fn init(allocator: std.mem.Allocator) !*HandlerNode {
        const node = try allocator.create(HandlerNode);
        node.* = .{
            .children = HandlerEdgeList.init(allocator),
            .handler = null,
        };
        return node;
    }

    pub fn deinit(self: *HandlerNode, allocator: std.mem.Allocator) void {
        for (self.children.items) |edge| {
            edge.next.*.deinit(allocator);
        }
        self.children.deinit();
        allocator.destroy(self);
    }
};

pub const HandlerTrie = struct {
    allocator: std.mem.Allocator,
    root: *HandlerNode,

    pub fn init(allocator: std.mem.Allocator) !*HandlerTrie {
        const trie = try allocator.create(HandlerTrie);
        trie.* = .{
            .allocator = allocator,
            .root = try HandlerNode.init(allocator),
        };
        return trie;
    }

    pub fn insert(self: *HandlerTrie, key: []const u8, handler: *const Handler) !void {
        var curr = self.root;
        for (key) |c| {
            var index = for (curr.children.items, 0..) |edge, i| {
                if (edge.value == c) break i;
            } else null;
            if (index == null) {
                const node = try HandlerNode.init(self.allocator);
                try curr.children.append(.{ .value = c, .next = node });
                index = curr.children.items.len - 1;
            }
            if (index) |i| {
                curr = curr.children.items[i].next;
            }
        }
        curr.handler = handler;
    }

    pub fn lookup(self: HandlerTrie, key: []const u8) ?*const Handler {
        var curr = self.root;
        for (key) |c| {
            const index = for (curr.children.items, 0..) |edge, i| {
                if (edge.value == c) break i;
            } else null;
            if (index) |i| {
                curr = curr.children.items[i].next;
            } else return null;
        }
        return curr.handler;
    }

    pub fn deinit(self: *HandlerTrie) void {
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
    const trie = try HandlerTrie.init(allocator);
    defer trie.deinit();

    try trie.insert("/test", testHandler);
    try trie.insert("/", testHandler);
    try trie.insert("GET /", testHandler);

    try expect(trie.lookup("/") == &testHandler);
    try expect(trie.lookup("/test") == &testHandler);
    try expect(trie.lookup("GET /") == &testHandler);
    try expect(trie.lookup("/teSt") == null);
    try expect(trie.lookup("/dne") == null);
}
