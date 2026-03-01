# jfai — 即焚AI

阅后即焚的内容分享服务。单二进制、零外部依赖，用 Zig 写的。

分享文字或文件，生成唯一链接，内容按次数或时间自动销毁。

## 特性

- 文字/文件分享，链接即用即焚
- 两种销毁模式：按查看次数 or 按存活时间
- Max TTL 保底机制，所有内容都有最大存活上限
- Token Bucket IP 限流
- 后台自动清理过期内容
- 内嵌 Web UI，开箱即用
- SQLite 存储元数据，文件系统存储上传文件
- 单二进制部署，无需外部数据库

## 构建 & 运行

```bash
# 构建
zig build

# 运行（默认监听 8080）
zig build run

# 或直接运行二进制
./zig-out/bin/jfai
```

## 部署

### Docker

```bash
docker run -d --name jfai \
  -p 8080:8080 \
  -v jfai-data:/data \
  -e JFAI_DATA_DIR=/data \
  ghcr.io/seeease/jf:latest
```

### 二进制

从 [Releases](https://github.com/seeease/jf/releases) 下载对应平台的二进制文件：

- `jfai-linux-amd64` / `jfai-linux-arm64`
- `jfai-macos-amd64` / `jfai-macos-arm64`

```bash
chmod +x jfai-linux-amd64
./jfai-linux-amd64
```

## 测试

```bash
zig build test
```

## 配置

通过环境变量配置，全部可选，有合理默认值：

| 环境变量 | 说明 | 默认值 |
|---|---|---|
| `JFAI_PORT` | 监听端口 | 8080 |
| `JFAI_DATA_DIR` | 数据存储目录 | ./data |
| `JFAI_MAX_TTL` | 最大存活秒数 | 86400 (24h) |
| `JFAI_MAX_VIEW_COUNT` | 次数模式最大查看次数 | 100 |
| `JFAI_MAX_FILE_SIZE` | 最大文件大小（字节） | 10485760 (10MB) |
| `JFAI_RATE_LIMIT` | 每秒请求数上限 | 10 |
| `JFAI_RATE_BURST` | 突发请求上限 | 20 |

示例：

```bash
JFAI_PORT=3000 JFAI_MAX_TTL=3600 ./zig-out/bin/jfai
```

## API

### POST /api/share — 创建分享

```bash
# 文字分享
curl -X POST http://localhost:8080/api/share \
  -H 'Content-Type: application/json' \
  -d '{"type":"text","content":"秘密消息","destroy_mode":"count","destroy_value":1}'

# 文件分享（base64 编码）
curl -X POST http://localhost:8080/api/share \
  -H 'Content-Type: application/json' \
  -d '{"type":"file","content":"'$(base64 < secret.pdf)'","file_name":"secret.pdf","mime_type":"application/pdf","destroy_mode":"time","destroy_value":300}'
```

响应：

```json
{"share_link":"/s/aB3xK9mP2qR7wZ5tY8nL1","id":"aB3xK9mP2qR7wZ5tY8nL1"}
```

### GET /s/{id} — 查看内容

- 文字类型返回 HTML 页面
- 文件类型返回二进制流（带正确 MIME）
- 不存在/已销毁返回 404

### GET /health — 健康检查

```json
{"status":"ok","active_contents":42,"storage_bytes":1048576}
```

### GET / — Web UI

浏览器打开即可使用的上传界面。

## 项目结构

```
src/
├── main.zig          # 主程序入口，组装所有组件
├── config.zig        # 环境变量配置
├── storage.zig       # SQLite + 文件系统存储层
├── id.zig            # 128-bit 随机 ID 生成（base62）
├── handler.zig       # HTTP 请求处理
├── router.zig        # 路由分发 + 限流中间件
├── rate_limiter.zig  # Token Bucket 限流器
└── cleaner.zig       # 后台过期清理线程
```

## 依赖

无外部依赖。SQLite 以 C 源码形式编译链接。

- Zig >= 0.15.0
- SQLite（已内嵌，`sqlite3.c` / `sqlite3.h`）
