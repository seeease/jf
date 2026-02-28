/// 后台清理线程
/// 定期调用 storage.cleanExpired() 清理过期内容
const std = @import("std");
const storage = @import("storage.zig");

pub const Cleaner = struct {
    store: *storage.Storage,
    interval_ns: u64, // 清理间隔（纳秒）
    should_stop: std.atomic.Value(bool),
    thread: ?std.Thread,

    /// 初始化 Cleaner，interval_sec 为清理间隔秒数
    pub fn init(store: *storage.Storage, interval_sec: u64) Cleaner {
        return .{
            .store = store,
            .interval_ns = interval_sec * std.time.ns_per_s,
            .should_stop = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    /// 启动清理线程
    pub fn start(self: *Cleaner) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// 通知停止并等待线程退出
    pub fn stop(self: *Cleaner) void {
        self.should_stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// 线程入口：循环 sleep + cleanExpired
    fn run(self: *Cleaner) void {
        while (!self.should_stop.load(.acquire)) {
            std.Thread.sleep(self.interval_ns);
            if (self.should_stop.load(.acquire)) break;
            const cleaned = self.store.cleanExpired();
            if (cleaned > 0) {
                std.log.info("清理了 {d} 条过期内容", .{cleaned});
            }
        }
    }
};

// ============ 测试 ============

test "Cleaner: init 和 stop 不崩溃" {
    // 使用内存数据库创建 storage
    var store = try storage.Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer store.deinit();

    var cleaner = Cleaner.init(&store, 1);
    // 未启动时 stop 也不应崩溃
    cleaner.stop();
    try std.testing.expect(cleaner.thread == null);
}

test "Cleaner: start 后 stop 正常退出" {
    var store = try storage.Storage.initInMemory(std.testing.allocator, 86400, 100, 10485760);
    defer store.deinit();

    // 使用极短间隔以便快速退出
    var cleaner = Cleaner.init(&store, 0);
    cleaner.interval_ns = 10 * std.time.ns_per_ms; // 10ms

    try cleaner.start();
    // 让线程跑一小会儿
    std.Thread.sleep(50 * std.time.ns_per_ms);
    cleaner.stop();

    try std.testing.expect(cleaner.thread == null);
}
