const std = @import("std");
const Config = @import("./config.zig").Config;
const protocol = @import("./protocol.zig");
const Conn = @import("./conn.zig").Conn;
const result = @import("./result.zig");

// TODO: Pool
pub const Pool = struct {
    config: Config,
    connections: std.ArrayList(*Conn),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    next_id: usize,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Pool {
        var pool = Pool{
            .config = config,
            .connections = std.ArrayList(*Conn).init(allocator),
            .mutex = std.Thread.Mutex{},
            .next_id = 0,
        };
        try pool.grow(3);
        return pool;
    }

    fn grow(self: *Pool, count: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_len = self.connections.items.len;
        if (current_len + count > self.config.max_connections) {
            return error.PoolExhausted;
        }

        for (0..count) |_| {
            const conn = try self.allocator.create(Conn);
            // TODO: add next_id
            conn.* = try Conn.init(self.allocator, self.next_id, self.config);
            self.next_id += 1;
            try self.connections.append(conn);
        }
    }

    /// Usage:
    /// `var conn = try pool.acquire();`
    pub fn acquire(self: *Pool) !*Conn {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Look for an idle connection
        for (self.connections.items) |conn| {
            if (!conn.active and conn.isValid()) {
                conn.active = true;
                return conn;
            }
        }

        // No idle connections; grow the pool if possible
        if (self.connections.items.len < self.config.max_connections) {
            const conn = try self.allocator.create(Conn);
            conn.* = try Conn.init(self.allocator, self.next_id, self.config);
            self.next_id += 1;
            conn.active = true;
            try self.connections.append(conn);
            return conn;
        }

        return error.NoAvailableConnections;
    }

    /// Release a specific connection in the pool
    pub fn release(self: *Pool, conn: *Conn) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Verify the connection belongs to this pool
        for (self.connections.items) |c| {
            if (c == conn) {
                conn.active = false;
                return;
            }
        }
        std.log.err("Invalid connection \n", .{});
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit();
    }
};
