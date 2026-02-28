/// jfai 主程序入口
/// 组装所有组件：配置、存储、限流、清理、HTTP 服务
const std = @import("std");
const config = @import("config.zig");
const storage = @import("storage.zig");
const handler_mod = @import("handler.zig");
const router_mod = @import("router.zig");
const rate_limiter = @import("rate_limiter.zig");
const cleaner = @import("cleaner.zig");

/// 自定义日志：带时间戳
pub const std_options: std.Options = .{
    .logFn = timestampLog,
};

fn timestampLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const ts = std.time.timestamp();
    const sec: u64 = @intCast(if (ts > 0) ts else 0);
    // 从 Unix 时间戳算年月日时分秒（UTC）
    const days = sec / 86400;
    const time_of_day = sec % 86400;
    const h = time_of_day / 3600;
    const m = (time_of_day % 3600) / 60;
    const s = time_of_day % 60;
    // 从 1970-01-01 起算天数 → 年月日
    var y: u64 = 1970;
    var remaining = days;
    while (true) {
        const ydays: u64 = if (isLeap(y)) 366 else 365;
        if (remaining < ydays) break;
        remaining -= ydays;
        y += 1;
    }
    const leap = isLeap(y);
    const mdays = [12]u64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var mon: u64 = 0;
    while (mon < 12 and remaining >= mdays[mon]) {
        remaining -= mdays[mon];
        mon += 1;
    }
    const day = remaining + 1;
    mon += 1;

    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    // 直接写 stderr 文件描述符，无缓冲，立即输出
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}] {s}: {s}" ++ format ++ "\n", .{ y, mon, day, h, m, s, level_txt, prefix } ++ args) catch return;
    const fd = std.posix.STDERR_FILENO;
    _ = std.posix.write(fd, msg) catch {};
}

fn isLeap(y: u64) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = config.load();

    // 初始化 Storage
    var store = try storage.Storage.init(
        allocator,
        cfg.data_dir,
        cfg.max_ttl,
        cfg.max_view_count,
        cfg.max_file_size,
    );
    defer store.deinit();

    // 初始化 RateLimiter
    var limiter = rate_limiter.RateLimiter.init(allocator, cfg.rate_limit, cfg.rate_burst);
    defer limiter.deinit();

    // 初始化 Handler 和 Router
    var handler = handler_mod.Handler.init(allocator, &store);
    var rtr = router_mod.Router.init(&handler, &limiter);

    // 启动 Cleaner 后台线程（固定 1 秒间隔）
    var clean = cleaner.Cleaner.init(&store, 1);
    try clean.start();
    defer clean.stop();

    // 启动 TCP 监听
    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, cfg.port);
    var server = try address.listen(.{ .reuse_address = false });
    defer server.deinit();

    std.log.info("jfai server started, listening on port {d}", .{cfg.port});

    // 请求循环（单线程）
    while (true) {
        const conn = server.accept() catch |err| {
            std.log.err("accept connection failed: {}", .{err});
            continue;
        };
        defer conn.stream.close();

        handleConnection(allocator, &rtr, conn) catch |err| {
            std.log.err("handle request failed: {}", .{err});
        };
    }
}

/// 处理单个 HTTP 连接
fn handleConnection(
    allocator: std.mem.Allocator,
    rtr: *router_mod.Router,
    conn: std.net.Server.Connection,
) !void {
    // 为 HTTP Server 创建 I/O 缓冲区
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var net_reader = conn.stream.reader(&read_buf);
    var net_writer = conn.stream.writer(&write_buf);

    var http_server = std.http.Server.init(net_reader.interface(), &net_writer.interface);
    var request = try http_server.receiveHead();

    // 提取请求方法和路径
    const method = @tagName(request.head.method);
    const path = request.head.target;

    // 读取请求体（POST 请求）
    var body: ?[]const u8 = null;
    defer if (body) |b| allocator.free(b);

    if (request.head.method == .POST) {
        if (request.head.content_length) |len| {
            if (len > 0 and len <= 11 * 1024 * 1024) { // 最大 11MB
                var body_buf: [4096]u8 = undefined;
                const body_reader = request.readerExpectNone(&body_buf);
                body = body_reader.readAlloc(allocator, @intCast(len)) catch null;
            }
        }
    }

    // 提取客户端 IP（IPv4 → u32）
    const client_ip = extractIpV4(conn.address);

    // 路由处理
    const resp = rtr.handleRequest(method, path, body, client_ip);
    defer {
        if (resp.allocated) allocator.free(resp.body);
        if (resp.content_type_allocated) allocator.free(resp.content_type);
    }

    // 构造额外响应头
    var retry_buf: [32]u8 = undefined;
    var extra_headers_buf: [2]std.http.Header = undefined;
    var header_count: usize = 0;

    extra_headers_buf[header_count] = .{
        .name = "content-type",
        .value = resp.content_type,
    };
    header_count += 1;

    if (resp.retry_after) |wait| {
        const retry_str = std.fmt.bufPrint(&retry_buf, "{d}", .{wait}) catch "1";
        extra_headers_buf[header_count] = .{
            .name = "retry-after",
            .value = retry_str,
        };
        header_count += 1;
    }

    // 发送响应
    try request.respond(resp.body, .{
        .status = @enumFromInt(resp.status),
        .extra_headers = extra_headers_buf[0..header_count],
    });
}

/// 从连接地址提取 IPv4 地址作为 u32（用于限流）
fn extractIpV4(addr: std.net.Address) u32 {
    if (addr.any.family == std.posix.AF.INET) {
        return @bitCast(addr.in.sa.addr);
    }
    // IPv6 或其他：取最后 4 字节作为哈希
    if (addr.any.family == std.posix.AF.INET6) {
        const bytes = addr.in6.sa.addr;
        return @bitCast(bytes[12..16].*);
    }
    return 0;
}
