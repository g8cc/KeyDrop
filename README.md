# KeyDrop

贴 key 即用的 AI API 配置分发工具(macOS 菜单栏应用)。

粘贴任意来源的 API key 内容,自动解析、测试、并写入各 AI 工具的配置,让中转站 / 共享 key 开箱即用。

## 功能

- **一键导入**:粘贴 key 内容(多行文本 / JSON / curl / zip / base64 / keyhub 格式),自动解析 URL、key、模型
- **真实测试**:导入前自动请求 `/models` 与 `/chat/completions` 验证 key 与模型可用性,拒绝死 key 与错误模型名(大小写敏感)
- **模型选择**:网关返回模型列表时弹出勾选,也可手动输入(同样逐一验证)
- **多目标写入**:
  - **cc-switch**(Claude Code / Codex / opencode):写入 cc-switch 数据库并激活,opencode 直接合并配置文件
  - **CPA**(cliproxy-api):写入 config.yaml
  - **DeepSeek Harness**:所选模型含 deepseek 时同步写入 `~/.dsh/settings.yaml` 与 `.credentials.yaml`
  - **Clash**:代理订阅直接合并
- **健康扫描**:自动定时检测 key 状态(ok / dead),与 cc-switch 对账
  - cc-switch 中已删除且 key 失效 → 自动标记删除
  - cc-switch 中已删除但 key 可用 → 标记可手动重新导入(一键恢复)
- **刷新模型**:重新测试端点,更新模型列表并同步所有目标(cc-switch / dsh)
- **编辑修复**:模型名 / 名称写错了可用 `edit` 命令修正,自动重新验证并同步
- **删除还原**:删除条目时自动从各目标移除并还原被热激活覆盖的 provider

## 安装

### 方式一:直接构建

需要 Xcode 命令行工具(macOS 14+):

```bash
swift build -c release
cp .build/release/KeyDrop ~/Applications/KeyDrop.app  # 或直接运行 .build/release/KeyDrop
```

### 方式二:打包分发

```bash
./make-app.sh     # 安装到 ~/Applications
./make-dist.sh    # 生成可分发的 zip
./make-dmg.sh     # 生成 dmg(带 Applications 拖拽)
```

## 使用

启动后出现在菜单栏,粘贴 key 内容点击导入即可。也可用命令行:

```bash
# 导入(自动测试)
KeyDrop --add "https://api.example.com/v1
sk-xxxx..."

# 强制导入(跳过测试)
KeyDrop --add <内容> --force

# 模型列表
KeyDrop list

# 刷新模型(重新测试端点并同步所有目标)
KeyDrop refresh <ID前缀>

# 编辑修正(模型名大小写写错时)
KeyDrop edit <ID前缀> --model Qwen3.8-27B
KeyDrop edit <ID前缀> --name 新名称 --no-verify

# 删除(自动从所有目标移除)
KeyDrop delete <ID前缀>

# 重新导入 cc-switch(provider 被删但 key 仍可用时)
KeyDrop reimport <ID前缀>
```

### 支持的粘贴格式

| 格式 | 示例 |
|---|---|
| 多行文本 | `https://api.example.com/v1` + `sk-xxxx` + 模型名 |
| JSON | `{"base_url":"...","api_key":"...","model":"..."}` |
| curl | `curl https://... -H "Authorization: Bearer sk-..."` |
| 环境变量 | `ANTHROPIC_BASE_URL=... ANTHROPIC_AUTH_TOKEN=...` |
| keyhub | `OpenAI:https://...` + `APIKEY <token>` |
| zip / base64 | 解压后按上述规则解析 |

## 配置

- 数据目录:`~/.keydrop/`(历史记录、偏好)
- 日志:`~/.keydrop/logs/`
- 测试与写入支持本地代理(界面可填,或 `--proxy http://127.0.0.1:7890`)

环境变量(测试 / CI 用):

| 变量 | 说明 |
|---|---|
| `KEYDROP_HOME` | 数据目录(默认 `~/.keydrop`) |
| `KEYDROP_CC_DB` | cc-switch 数据库路径 |
| `KEYDROP_CC_SETTINGS` | cc-switch switch settings 路径 |
| `KEYDROP_CLAUDE_SETTINGS` / `KEYDROP_CODEX_CONFIG` / `KEYDROP_OPENCODE_CONFIG` | 各工具配置文件路径 |
| `KEYDROP_DSH_SETTINGS` / `KEYDROP_DSH_CREDENTIALS` | DeepSeek Harness 配置路径 |
| `KEYDROP_PROXY` | 默认代理 |

## 隐私

所有 key 仅存于本机(`~/.keydrop/history.json`,权限 600),不上传任何数据。健康扫描仅向目标网关发测试请求。

## License

MIT
