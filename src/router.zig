/// 请求路由
/// 解析请求路径和方法，分发到对应 handler，集成限流中间件
const std = @import("std");
const handler_mod = @import("handler.zig");
const rate_limiter = @import("rate_limiter.zig");

/// HTTP 响应结构体
pub const Response = struct {
    status: u16,
    content_type: []const u8,
    body: []const u8,
    retry_after: ?u32 = null, // 429 时设置
    allocated: bool = false, // body 是否需要调用方释放
    content_type_allocated: bool = false, // content_type 是否需要调用方释放
};

pub const Router = struct {
    handler: *handler_mod.Handler,
    limiter: *rate_limiter.RateLimiter,

    pub fn init(h: *handler_mod.Handler, limiter: *rate_limiter.RateLimiter) Router {
        return .{ .handler = h, .limiter = limiter };
    }

    /// 处理请求：先限流检查，再路由分发
    pub fn handleRequest(
        self: *Router,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
        client_ip: u32,
    ) Response {
        // 限流检查
        if (!self.limiter.allow(client_ip)) {
            const wait = self.limiter.retryAfter(client_ip);
            return .{
                .status = 429,
                .content_type = "application/json",
                .body = "{\"error\":\"rate limited\"}",
                .retry_after = wait,
            };
        }

        // 路由分发
        return self.dispatch(method, path, body);
    }

    /// 根据 method + path 分发到对应 handler
    fn dispatch(self: *Router, method: []const u8, path: []const u8, body: ?[]const u8) Response {
        // POST /api/share
        if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/share")) {
            return self.handler.handleCreateShare(body);
        }

        // GET 请求
        if (std.mem.eql(u8, method, "GET")) {
            // GET /health
            if (std.mem.eql(u8, path, "/health")) {
                return self.handler.handleHealth();
            }

            // GET /
            if (std.mem.eql(u8, path, "/")) {
                return self.handler.handleWebUI();
            }

            // GET /s/{id} — 提取路径中的 ID
            if (extractContentId(path)) |content_id| {
                return self.handler.handleViewContent(content_id);
            }
        }

        // 未匹配路由
        return notFound();
    }
};

/// 从路径 /s/{id} 中提取 ID，不匹配返回 null
fn extractContentId(path: []const u8) ?[]const u8 {
    if (path.len < 4) return null; // 至少 "/s/x"
    if (!std.mem.startsWith(u8, path, "/s/")) return null;
    const content_id = path[3..];
    if (content_id.len == 0) return null;
    return content_id;
}

/// 404 响应
fn notFound() Response {
    return .{
        .status = 404,
        .content_type = "application/json",
        .body = "{\"error\":\"not found\"}",
    };
}

// ============ 测试 ============

test "extractContentId: 正常路径提取 ID" {
    const result = extractContentId("/s/abc123");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("abc123", result.?);
}

test "extractContentId: 长 ID 提取" {
    const result = extractContentId("/s/aB3xK9mP2qR7wZ5tY8nL1");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("aB3xK9mP2qR7wZ5tY8nL1", result.?);
}

test "extractContentId: 不匹配的路径返回 null" {
    try std.testing.expect(extractContentId("/other/path") == null);
    try std.testing.expect(extractContentId("/s/") == null);
    try std.testing.expect(extractContentId("/s") == null);
    try std.testing.expect(extractContentId("/") == null);
    try std.testing.expect(extractContentId("") == null);
}

test "路由: POST /api/share 正确分发" {
    var store = try @import("storage.zig").Storage.initInMemory(
        std.testing.allocator,
        86400,
        100,
        10485760,
    );
    defer store.deinit();

    var handler = handler_mod.Handler.init(std.testing.allocator, &store);
    var limiter = rate_limiter.RateLimiter.init(std.testing.allocator, 10.0, 20);
    defer limiter.deinit();

    var rtr = Router.init(&handler, &limiter);
    const resp = rtr.handleRequest("POST", "/api/share", null, 1);

    // 无 body 返回 400
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "路由: GET /s/{id} 正确分发" {
    var store = try @import("storage.zig").Storage.initInMemory(
        std.testing.allocator,
        86400,
        100,
        10485760,
    );
    defer store.deinit();

    var handler = handler_mod.Handler.init(std.testing.allocator, &store);
    var limiter = rate_limiter.RateLimiter.init(std.testing.allocator, 10.0, 20);
    defer limiter.deinit();

    var rtr = Router.init(&handler, &limiter);
    const resp = rtr.handleRequest("GET", "/s/abc123", null, 1);

    // handler 对不存在的 ID 返回 404
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

test "路由: GET /health 正确分发" {
    var store = try @import("storage.zig").Storage.initInMemory(
        std.testing.allocator,
        86400,
        100,
        10485760,
    );
    defer store.deinit();

    var handler = handler_mod.Handler.init(std.testing.allocator, &store);
    var limiter = rate_limiter.RateLimiter.init(std.testing.allocator, 10.0, 20);
    defer limiter.deinit();

    var rtr = Router.init(&handler, &limiter);
    const resp = rtr.handleRequest("GET", "/health", null, 1);

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    // 健康检查返回动态分配的 JSON
    if (resp.allocated) std.testing.allocator.free(resp.body);
}

test "路由: GET / 正确分发" {
    var store = try @import("storage.zig").Storage.initInMemory(
        std.testing.allocator,
        86400,
        100,
        10485760,
    );
    defer store.deinit();

    var handler = handler_mod.Handler.init(std.testing.allocator, &store);
    var limiter = rate_limiter.RateLimiter.init(std.testing.allocator, 10.0, 20);
    defer limiter.deinit();

    var rtr = Router.init(&handler, &limiter);
    const resp = rtr.handleRequest("GET", "/", null, 1);

    // Web UI 返回 200 和 HTML 内容
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", resp.content_type);
}

test "路由: 未知路径返回 404" {
    var store = try @import("storage.zig").Storage.initInMemory(
        std.testing.allocator,
        86400,
        100,
        10485760,
    );
    defer store.deinit();

    var handler = handler_mod.Handler.init(std.testing.allocator, &store);
    var limiter = rate_limiter.RateLimiter.init(std.testing.allocator, 10.0, 20);
    defer limiter.deinit();

    var rtr = Router.init(&handler, &limiter);

    // 未知 GET 路径
    const r1 = rtr.handleRequest("GET", "/unknown", null, 1);
    try std.testing.expectEqual(@as(u16, 404), r1.status);

    // 未知 POST 路径
    const r2 = rtr.handleRequest("POST", "/other", null, 1);
    try std.testing.expectEqual(@as(u16, 404), r2.status);

    // DELETE 方法
    const r3 = rtr.handleRequest("DELETE", "/api/share", null, 1);
    try std.testing.expectEqual(@as(u16, 404), r3.status);
}

test "路由: 限流拒绝返回 429" {
    var store = try @import("storage.zig").Storage.initInMemory(
        std.testing.allocator,
        86400,
        100,
        10485760,
    );
    defer store.deinit();

    var handler = handler_mod.Handler.init(std.testing.allocator, &store);
    // 容量为 1，第 2 次请求就会被拒绝
    var limiter = rate_limiter.RateLimiter.init(std.testing.allocator, 1.0, 1);
    defer limiter.deinit();

    var rtr = Router.init(&handler, &limiter);

    // 第 1 次：放行
    const r1 = rtr.handleRequest("GET", "/health", null, 100);
    try std.testing.expect(r1.status != 429);
    // 健康检查返回动态分配的 JSON，需要释放
    if (r1.allocated) std.testing.allocator.free(r1.body);

    // 第 2 次：被限流
    const r2 = rtr.handleRequest("GET", "/health", null, 100);
    try std.testing.expectEqual(@as(u16, 429), r2.status);
    try std.testing.expect(r2.retry_after != null);
}
