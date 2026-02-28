/// ID 生成器
/// 128-bit 随机数 base62 编码，输出 22 字符固定长度字符串
const std = @import("std");

/// base62 字符集：0-9, a-z, A-Z
const charset = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// 生成 22 字符的 base62 随机 ID
/// 使用 std.crypto.random 生成 128-bit 随机数，然后 base62 编码
pub fn generate() [22]u8 {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    return encode(random_bytes);
}

/// 将 16 字节（128-bit）数据编码为 22 字符 base62 字符串
/// 算法：将字节视为大整数，反复除以 62 取余数作为字符索引
fn encode(bytes: [16]u8) [22]u8 {
    // 将 16 字节拷贝为可变的大整数（大端序）
    var num: u128 = std.mem.readInt(u128, &bytes, .big);

    var result: [22]u8 = .{'0'} ** 22;

    // 从低位到高位填充
    var i: usize = 22;
    while (i > 0) {
        i -= 1;
        const rem: u7 = @intCast(num % 62);
        result[i] = charset[rem];
        num /= 62;
    }

    return result;
}

// ============ 测试 ============

fn isBase62Char(c: u8) bool {
    return (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z');
}

test "generate: 输出长度固定为 22" {
    const id = generate();
    try std.testing.expectEqual(@as(usize, 22), id.len);
}

test "generate: 所有字符属于 base62 字符集" {
    const id = generate();
    for (id) |c| {
        try std.testing.expect(isBase62Char(c));
    }
}

test "generate: 两次调用产生不同 ID" {
    const id1 = generate();
    const id2 = generate();
    try std.testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "encode: 全零输入产生全 '0' 输出" {
    const zeros = [_]u8{0} ** 16;
    const result = encode(zeros);
    for (result) |c| {
        try std.testing.expectEqual(@as(u8, '0'), c);
    }
}

test "encode: 全 0xFF 输入产生有效 base62 输出" {
    const max_bytes = [_]u8{0xFF} ** 16;
    const result = encode(max_bytes);
    // 所有字符都应在 base62 字符集内
    for (result) |c| {
        try std.testing.expect(isBase62Char(c));
    }
}
