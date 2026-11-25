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

1.4.65（2026-11-25）补齐 Responses-only 的完整自动导入链路，包括直接粘贴 `/v1/responses` 和无 `/models` 时显式提供模型。请求命令、刷新与编辑沿用实测协议。真实 KeyDrop CLI → 本机 Magpie → 临时 Responses 上游的原生调用与完整生命周期也已验证。

新写入的记录保存 Magpie 实例标识（地址摘要，不含管理 key）。修改管理链接不会自动迁移旧记录；旧记录的同步、重放、删除要求恢复原实例设置。成功同步旧版记录时会补齐实例标识。远端账本的实例标识不会用于认领本机实例。

同步失败显示「目标配置同步失败，需重试」，不会因上游探测成功而进入可用区。行内重新同步或刷新成功后清除状态。本机命令失败但配置完全读回一致时仍登记归属。Web 模式除核对地址和所选模型外，还调用官方 `/api/provider/key` 接口核验实际密钥；列表中相同的密钥掩码不能证明轮换已生效。核验接口不可用时报告失败，不把写入当作已确认。

账本保存失败时，本次导入返回失败；重复导入返回原有记录，并且不追加本次探测数据。Magpie 原有配置会尝试恢复，首次新增的 Magpie 目标会尝试清理。回滚前核对地址、实际密钥和模型，发现已被其他写入者修改则停止回滚并报告原因。偏好保存失败单独提示，不撤销已经保存的导入记录。
