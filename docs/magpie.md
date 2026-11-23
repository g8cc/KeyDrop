# Magpie 导入

在 KeyDrop 顶栏开启 **Magpie**，粘贴 URL、API key 和模型后正常导入。多个目标可同时启用。已有记录可通过行内「同步到… → Magpie」补充导入。

本机安装在 `/Applications/magpie.app`、`~/Applications/magpie.app` 或标准 CLI 路径时自动识别，无需启动 Web 管理页。KeyDrop 调用 Magpie 官方的 `provider add/set/rm`，由 Magpie 处理自身配置锁和运行时通知，写后独立读取 `providers.json` 核验。不会自动切换 agent 当前使用的模型；到 Magpie 中选择新 provider 的模型即可。

远程实例可点 Magpie 旁的齿轮或菜单栏「Magpie 设置…」，填入 Web 管理页完整链接（含 `?k=`）。模型网关的端口与管理页端口可能不同。清空链接恢复本机自动模式；显式链接错误时会报错，不会改写另一个本机实例。

```sh
KeyDrop --add '<URL 和 key>' --magpie --no-cc --no-grok --no-cpa --no-dsh --model glm-5.2
```

`--no-magpie` 可覆盖保存的开关。默认关闭新目标，避免升级后给原先导入流程增加写入。多 key 粘贴仍遵循现有 CPA 凭据池导入规则；Magpie 目标使用单 key 记录。

同步使用完整 KeyDrop 记录 ID 作为 Magpie provider ID，显示名为 `KeyDrop-<id8>-<host>`。重复同步更新原记录，兼容历史短 ID。编辑、刷新、迁移重放和订阅更新都会维护原记录；删除失败时保留目标归属以便重试。仅同显示名的用户 provider 不会被覆盖或删除。

协议根据 KeyDrop 保存的探测结果映射，默认 OpenAI Chat；Claude 原生协议写入 Anthropic 根路径，Responses 协议写入版本挂载路径。不会虚报三种原生协议均可用，其他客户端协议由 Magpie 进行转换。导入成功表示配置写入并核验成功；运行时健康仍以实际模型调用为准。

开发验证：`KEYDROP_TEST_FILTER=Magpie .build/debug/KeyDropTestRunner`。测试可使用 `KEYDROP_MAGPIE_BIN` 和 `KEYDROP_MAGPIE_CONFIG_HOME` 指定隔离的 CLI 与配置根目录（该目录下的 `magpie/providers.json`）。本机官方 CLI 未额外指定时遵循 `XDG_CONFIG_HOME`。

2026-11-23 在 Magpie 0.1.2122 实测：临时本地上游的 OpenAI Chat、Anthropic Messages、Responses 经真实 Magpie 网关返回正确响应；重复同步、换 key、精选模型、删除均通过，原有 providers 校验一致。测试不调用付费上游。
