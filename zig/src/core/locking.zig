const std = @import("std");

pub const Lock = struct {
    path: []const u8,
    agent_id: []const u8,
    expires_at_ms: i64,

    pub fn deinit(self: *Lock, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.agent_id);
    }
};

pub const LockManager = struct {
    allocator: std.mem.Allocator,
    locks: std.StringHashMap(Lock),
    mutex: std.Thread.Mutex,
    timeout_ms: i64,

    pub fn init(allocator: std.mem.Allocator, timeout_ms: i64) LockManager {
        return .{
            .allocator = allocator,
            .locks = std.StringHashMap(Lock).init(allocator),
            .mutex = .{},
            .timeout_ms = timeout_ms,
        };
    }

    pub fn deinit(self: *LockManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.locks.iterator();
        while (it.next()) |entry| {
            var lock = entry.value_ptr.*;
            lock.deinit(self.allocator);
        }
        self.locks.deinit();
    }

    pub fn acquire(self: *LockManager, path: []const u8, agent_id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();

        if (self.locks.getPtr(path)) |lock| {
            if (now < lock.expires_at_ms and !std.mem.eql(u8, lock.agent_id, agent_id)) {
                return false; // Already locked by someone else
            }
            // Update existing lock or takeover expired lock
            self.allocator.free(lock.agent_id);
            lock.agent_id = try self.allocator.dupe(u8, agent_id);
            lock.expires_at_ms = now + self.timeout_ms;
            return true;
        }

        const new_lock = Lock{
            .path = try self.allocator.dupe(u8, path),
            .agent_id = try self.allocator.dupe(u8, agent_id),
            .expires_at_ms = now + self.timeout_ms,
        };
        try self.locks.put(new_lock.path, new_lock);
        return true;
    }

    pub fn release(self: *LockManager, path: []const u8, agent_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.locks.getPtr(path)) |lock| {
            if (std.mem.eql(u8, lock.agent_id, agent_id)) {
                var entry = self.locks.fetchRemove(path).?;
                entry.value.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    pub fn heartbeat(self: *LockManager, path: []const u8, agent_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.locks.getPtr(path)) |lock| {
            if (std.mem.eql(u8, lock.agent_id, agent_id)) {
                lock.expires_at_ms = std.time.milliTimestamp() + self.timeout_ms;
                return true;
            }
        }
        return false;
    }

    pub fn check(self: *LockManager, path: []const u8) ?Lock {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.locks.get(path)) |lock| return lock;
        return null;
    }

    /// Remove all expired locks. Returns count of reaped locks.
    pub fn reap_stale(self: *LockManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        var to_remove = std.ArrayList([]const u8){};
        defer to_remove.deinit(self.allocator);

        var it = self.locks.iterator();
        while (it.next()) |entry| {
            if (now >= entry.value_ptr.expires_at_ms) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.locks.fetchRemove(key)) |entry| {
                var lock = entry.value;
                lock.deinit(self.allocator);
            }
        }

        return to_remove.items.len;
    }

    pub fn list_agent_locks(self: *LockManager, agent_id: []const u8) []Lock {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(Lock){};
        var it = self.locks.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.agent_id, agent_id)) {
                result.append(self.allocator, entry.value_ptr.*) catch continue;
            }
        }
        return result.toOwnedSlice(self.allocator) catch &[_]Lock{};
    }

    pub fn list_all(self: *LockManager) []Lock {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(Lock){};
        var it = self.locks.iterator();
        while (it.next()) |entry| {
            result.append(self.allocator, entry.value_ptr.*) catch continue;
        }
        return result.toOwnedSlice(self.allocator) catch &[_]Lock{};
    }
};
