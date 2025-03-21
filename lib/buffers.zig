const std = @import("std");

pub const BufferPoolOptions = struct {
    allocator: std.mem.Allocator,
    numBuffers: u16,
    bufferSize: u16,
};

const Queue = std.DoublyLinkedList(u8);
pub const Buffer = []u8;
const Buffers = std.ArrayList(Buffer);

pub const BufferPool = struct {
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
            errdefer options.allocator.destroy(node);
            node.data = @intCast(i);
            queue.append(node);
            const buffer = try options.allocator.alloc(u8, options.bufferSize);
            errdefer options.allocator.free(buffer);
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
