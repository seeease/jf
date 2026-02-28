/// jfai 配置模块
/// 从环境变量读取所有配置项，提供合理默认值
const std = @import("std");

pub const Config = struct {
    port: u16,
    data_dir: []const u8,
    max_ttl: u64, // 秒
    max_view_count: u32,
    max_file_size: u64, // 字节
    rate_limit: f64, // 每秒令牌数
    rate_burst: u32, // 突发上限
    clean_interval: u64, // 秒
};

/// 从环境变量加载配置，缺失时使用默认值
pub fn load() Config {
    return .{
        .port = getEnvU16("JFAI_PORT", 8080),
        .data_dir = std.posix.getenv("JFAI_DATA_DIR") orelse "./data",
        .max_ttl = getEnvU64("JFAI_MAX_TTL", 86400),
        .max_view_count = getEnvU32("JFAI_MAX_VIEW_COUNT", 100),
        .max_file_size = getEnvU64("JFAI_MAX_FILE_SIZE", 10485760),
        .rate_limit = getEnvF64("JFAI_RATE_LIMIT", 10.0),
        .rate_burst = getEnvU32("JFAI_RATE_BURST", 20),
        .clean_interval = getEnvU64("JFAI_CLEAN_INTERVAL", 60),
    };
}

fn getEnvU16(name: []const u8, default: u16) u16 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u16, val, 10) catch default;
}

fn getEnvU32(name: []const u8, default: u32) u32 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u32, val, 10) catch default;
}

fn getEnvU64(name: []const u8, default: u64) u64 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseInt(u64, val, 10) catch default;
}

fn getEnvF64(name: []const u8, default: f64) f64 {
    const val = std.posix.getenv(name) orelse return default;
    return std.fmt.parseFloat(f64, val) catch default;
}

test "默认配置加载" {
    const cfg = load();
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqualStrings("./data", cfg.data_dir);
    try std.testing.expectEqual(@as(u64, 86400), cfg.max_ttl);
    try std.testing.expectEqual(@as(u32, 100), cfg.max_view_count);
    try std.testing.expectEqual(@as(u64, 10485760), cfg.max_file_size);
    try std.testing.expectEqual(@as(f64, 10.0), cfg.rate_limit);
    try std.testing.expectEqual(@as(u32, 20), cfg.rate_burst);
    try std.testing.expectEqual(@as(u64, 60), cfg.clean_interval);
}
