/// 限流器
/// 基于 Token Bucket 算法的 IP 限流
const std = @import("std");

/// 令牌桶
const Bucket = struct {
    tokens: f64,
    last_refill: i64, // 纳秒时间戳
};

pub const RateLimiter = struct {
    buckets: std.AutoHashMap(u32, Bucket),
    rate: f64, // 每秒令牌数
    capacity: u32, // 突发上限
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, rate: f64, capacity: u32) RateLimiter {
        return .{
            .buckets = std.AutoHashMap(u32, Bucket).init(allocator),
            .rate = rate,
            .capacity = capacity,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *RateLimiter) void {
        self.buckets.deinit();
    }

    /// 判断该 IP 是否放行，放行则消耗一个令牌
    pub fn allow(self: *RateLimiter, ip: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        return self.allowInner(ip, now_ns);
    }

    /// 返回该 IP 需要等待的秒数（向上取整）
    pub fn retryAfter(self: *RateLimiter, ip: u32) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now_ns: i64 = @intCast(std.time.nanoTimestamp());
        return self.retryAfterInner(ip, now_ns);
    }

    // --- 内部实现，不加锁，方便测试注入时间 ---

    fn refill(self: *RateLimiter, bucket: *Bucket, now_ns: i64) void {
        const elapsed_ns = now_ns - bucket.last_refill;
        if (elapsed_ns <= 0) return;
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const cap_f: f64 = @floatFromInt(self.capacity);
        bucket.tokens = @min(cap_f, bucket.tokens + elapsed_s * self.rate);
        bucket.last_refill = now_ns;
    }

    fn getOrCreateBucket(self: *RateLimiter, ip: u32, now_ns: i64) *Bucket {
        const gop = self.buckets.getOrPut(ip) catch unreachable;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .tokens = @floatFromInt(self.capacity),
                .last_refill = now_ns,
            };
        }
        return gop.value_ptr;
    }

    fn allowInner(self: *RateLimiter, ip: u32, now_ns: i64) bool {
        const bucket = self.getOrCreateBucket(ip, now_ns);
        self.refill(bucket, now_ns);
        if (bucket.tokens >= 1.0) {
            bucket.tokens -= 1.0;
            return true;
        }
        return false;
    }

    fn retryAfterInner(self: *RateLimiter, ip: u32, now_ns: i64) u32 {
        const bucket = self.getOrCreateBucket(ip, now_ns);
        self.refill(bucket, now_ns);
        if (bucket.tokens >= 1.0) return 0;
        // 需要等待的秒数 = ceil((1 - tokens) / rate)
        const wait = (1.0 - bucket.tokens) / self.rate;
        return @intFromFloat(@ceil(wait));
    }
};

// ============ 测试 ============

test "首次请求应放行" {
    var limiter = RateLimiter.init(std.testing.allocator, 10.0, 5);
    defer limiter.deinit();
    try std.testing.expect(limiter.allow(1));
}

test "突发请求在容量内全部放行" {
    var limiter = RateLimiter.init(std.testing.allocator, 1.0, 3);
    defer limiter.deinit();
    const now_ns: i64 = 1_000_000_000_000;
    // 容量为 3，连续 3 次应全部放行
    try std.testing.expect(limiter.allowInner(1, now_ns));
    try std.testing.expect(limiter.allowInner(1, now_ns));
    try std.testing.expect(limiter.allowInner(1, now_ns));
}

test "耗尽容量后拒绝请求" {
    var limiter = RateLimiter.init(std.testing.allocator, 1.0, 2);
    defer limiter.deinit();
    const now_ns: i64 = 1_000_000_000_000;
    // 耗尽 2 个令牌
    try std.testing.expect(limiter.allowInner(1, now_ns));
    try std.testing.expect(limiter.allowInner(1, now_ns));
    // 第 3 次应被拒绝
    try std.testing.expect(!limiter.allowInner(1, now_ns));
}

test "被拒绝时 retryAfter 返回大于 0" {
    var limiter = RateLimiter.init(std.testing.allocator, 1.0, 1);
    defer limiter.deinit();
    const now_ns: i64 = 1_000_000_000_000;
    // 耗尽令牌
    try std.testing.expect(limiter.allowInner(1, now_ns));
    try std.testing.expect(!limiter.allowInner(1, now_ns));
    // retryAfter 应 > 0
    const wait = limiter.retryAfterInner(1, now_ns);
    try std.testing.expect(wait > 0);
}

test "不同 IP 互相独立" {
    var limiter = RateLimiter.init(std.testing.allocator, 1.0, 1);
    defer limiter.deinit();
    const now_ns: i64 = 1_000_000_000_000;
    // IP=1 耗尽
    try std.testing.expect(limiter.allowInner(1, now_ns));
    try std.testing.expect(!limiter.allowInner(1, now_ns));
    // IP=2 不受影响
    try std.testing.expect(limiter.allowInner(2, now_ns));
}

test "令牌随时间恢复" {
    var limiter = RateLimiter.init(std.testing.allocator, 1.0, 1);
    defer limiter.deinit();
    const now_ns: i64 = 1_000_000_000_000; // 固定起始时间
    // 耗尽
    try std.testing.expect(limiter.allowInner(1, now_ns));
    try std.testing.expect(!limiter.allowInner(1, now_ns));
    // 过 2 秒后应恢复
    const later_ns = now_ns + 2_000_000_000;
    try std.testing.expect(limiter.allowInner(1, later_ns));
}
