# KeyDrop 导入链路全景

> 适用版本 v1.4.30。本文回答三类问题:
> ① 一个 key 从贴进 KeyDrop 到落到各工具,中间发生了什么(按顺序);
> ② 每个目标(Claude Code / Codex / OpenCode / Grok Build / CPA / DSH)各自怎么写、写到哪;
> ③ 多个目标同时命中时,谁优先、什么绝不覆盖。

---

## 0. 一图流

```
                          ┌──────────────────────────────────────────────┐
                          │                 KeyDrop 导入                 │
                          │  (菜单栏粘贴 / CLI keydrop add / cpa-sync)   │
                          └───────────────────┬──────────────────────────┘
                                              │ 解析 url+key+模型 → 测试 → 家族路由
          ┌───────────────┬───────────────────┼───────────────────┬──────────────┐
          ▼               ▼                   ▼                   ▼              ▼
   ┌────────────┐  ┌────────────┐    ┌────────────────┐  ┌────────────┐ ┌───────────┐
   │  cc-switch │  │ Grok Build │    │  CPA(CLIProxy) │  │    DSH     │ │   Clash   │
   │  (Claude   │  │ (grok 系)  │    │ (所有家族通用) │  │(deepseek系)│ │(代理节点) │
   │ Code/Codex/│  └────────────┘    └───────┬────────┘  └────────────┘ └───────────┘
   │  OpenCode) │                            │ 本地端点 http://127.0.0.1:8317/v1
   └──────┬─────┘                            ▼
          │ DB + live 配置            ┌─────────────────────┐
          ▼                           │ 任意 OpenAI 兼容客户端│ ←「CPA 常驻入口」
   ┌──────────────┐                   │ opencode / pi / 其他 │   让这些工具免配置
   │ 各编码 Agent  │                   └─────────────────────┘   消费 127.0.0.1:8317
   │ Claude Code  │
   │ Codex CLI    │
   │ OpenCode     │
   └──────────────┘
```

一句话:**KeyDrop 是"账本 + 写入器"**。它自己不跑任何服务;它把解析出的 url/key/模型写进各工具的配置文件或数据库,并维护一条历史账本(`~/.keydrop/history.json`)保证删得掉、对得上账。

---

## 1. 组件与各自的地盘(谁写谁家哪个文件)

| 组件 | KeyDrop 写什么 | 文件/位置 | KeyDrop 记的账 |
|---|---|---|---|
| **KeyDrop 自身** | 历史账本 + 偏好 | `~/.keydrop/history.json`、`~/.keydrop/prefs.json` | 每条导入一个 entry:id、url、key、models、targets |
| **cc-switch** | provider 行 + 激活状态 + live 配置 | `~/.cc-switch/cc-switch.db`(providers/provider_endpoints 表)、`~/.cc-switch/settings.json`(currentProvider 指针)、live:`~/.claude/settings.json`、`~/.codex/config.toml`+`auth.json`、opencode.json | `targets: ["ccswitch" 或 "ccswitch-<type>"]` + `ccProviderID` |
| **CPA(CLIProxyAPI)** | 上游 key/模型 → openai-compatibility 聚合条目 | CPA 的 `config.yaml`(本机:`~/Documents/work/code/AI/AIworkspace/cliproxyapi/config.yaml`) | `targets: ["cpa"]` + `cpaConfigPath` |
| **DSH(DeepSeek Harness)** | route(provider 块)+ 凭据 | `~/.dsh/settings.yaml` + `~/.dsh/.credentials.yaml`(凭据必须缩进嵌在 `refs:` 内) | `targets: ["dsh"]` |
| **Grok Build** | 每模型一段(baseURL+key) | Grok 配置文件(条目 `grokConfigPath` 记路径) | `targets: ["grok"]` |
| **Clash(mihomo-party)** | 代理节点 yaml | `~/Library/Application Support/mihomo-party/profiles/` | `targets: ["clash"]` |
| **生图渠道** | 独立 CPA 生图聚合条目(models 带 `image: true`) | CPA config.yaml + `~/.keydrop/image-channel.json` | 独立 image 条目 |

**本机关键常量**:CPA 本地端点 `http://127.0.0.1:8317`(Docker/自定义可在 KeyDrop 设置改),客户端消费 key = CPA config.yaml 里的 `api-keys`(即"我的 CPA 的 apiKey")。

---

## 2. 核心概念

- **targets(账本标签)**:entry 上的每个 tag 对应一个真实存在的外部产物。`["ccswitch","cpa","dsh"]` = 这条 key 同时写入了 cc-switch、CPA、DSH 三处。删除/对账时**凭 tag 找到产物并清理**;产物写入失败绝不记 tag,tag 摘除前必先删成功(账本不变量)。
- **精选模型(curated models)**:条目 `models` 字段 = 用户确认过的模型列表。CPA 聚合条目已有非空 models 时视为精选——**再导入只合 key,绝不把探测到的全量回填**。
- **聚合条目(aggregated entry)**:CPA config.yaml `openai-compatibility:` 段下、以 `name = 域名[:端口]` 命名的一组配置;同 baseURL 的多把 key 归一组,**CPA 运行时在该组内轮询**。
- **CPA 常驻入口(CPA resident)**:KeyDrop 主动在 cc-switch/DSH 里建的一条"被动入口",指向 `http://127.0.0.1:8317/v1` + CPA 客户端 key。让 opencode/pi 等工具不用手动配置就能消费 CPA 后面的所有 key。
- **live 配置**:各 Agent 真正读取的文件(Claude Code 读 `~/.claude/settings.json` 等)。cc-switch DB 里存的是"每个 provider 的配置",**激活哪个 provider = 把它的配置写到 live**。
- **DB current**:cc-switch `providers` 表的 `is_current=1` 行 + `settings.json` 的 `currentProvider<Type>` 指针。

---

## 3. 导入主流程(Core.add,按执行顺序)

### 阶段 0:粘贴内容分流(在解析 key 之前)

| 粘贴内容 | 判定 | 去向 |
|---|---|---|
| 代理节点行(ss://、socks5:// 等,占比过半) | clashOnly | **Clash 导入**,与 LLM key 流程完全分离 |
| 单条 `http(s)://` 链接 | 订阅探测 | 先尝试拉订阅转 Clash;失败才继续按 key 解析 |
| 含 `baseurl:`/`key(base64):` 的多行文本、裸 key、URL+key | Parser.parseWithFallback | 进入 key 导入流程 |

### 阶段 1:解析与补全
- 解析出 `url` / `key` / 模型候选(支持 `key(base64)`、多行格式)。
- 只贴 key 不贴 URL → **复用上次导入的 URL**("URL 复用上次"提示)。

### 阶段 2:去重防呆(以历史账本为准)
| 情形 | 行为 |
|---|---|
| 同 key + 同 URL 已存在 | **幂等更新**:刷新该条目与各产物,不新建 |
| 同 key 但 URL 不同 | **报错拒绝**(防把同 key 换站覆盖错);CLI `--force` 可越过 |
| 多把 key(≥2) | **只走 CPA**(单 key 才写 cc-switch 等单文件目标),见 §6.2 |

### 阶段 3:可用性测试(force=false 时)
- **直连优先**,失败自动补本机代理(设置里的 proxy 或自动探测 7890/7891 等)再测一遍 → `needsProxy` 记入健康详情("直连失败,需代理,经代理验证通过")。
- 401/403 → `authFailed`(key 失效);429/402 → `quotaExhausted`;chat 探测的可用/限流模型分开记录。

### 阶段 4:模型列表确定(优先级从高到低)

| 优先级 | 来源 | 说明 |
|---|---|---|
| 1 | `--model` 显式指定 | 逐个 chat 实测验证;**全失败 → 整次导入失败**,绝不偷换成别的 |
| 2 | 贴入文本携带的模型 | 同样逐个 chat 验证;全失败 → **回落站点模型目录**(避免一个过期模型名毁掉整次导入) |
| 3 | 站点 `/models` 目录 ≤5 个 | 全部导入 |
| 4 | 站点目录 >5 个 | 弹窗勾选(UI);无选择器(CLI)→ 贴入文本带主模型则用主模型,否则全量导入 |
| 5 | 站点无 /models 目录 | 弹窗手输,逐个 chat 验证,通过的保留 |
| 6 | 部分模型限流 | 强制弹窗挑选(可用排前、限流沉底);CLI 自动排除限流项 |

关键规则:**用户勾选/显式指定的模型不再过 `looksLikeModel` 启发式去噪**(真实事故:step-3.7-flash 这类新命名被当域名误杀);**纯图生/嵌入/语音模型(image/embed/tts/ocr 等)永不作为激活模型**。

### 阶段 5:路由决策 → 决定"进哪个 Agent"(详见 §5)

### 阶段 6:按开关依次写入(顺序固定,失败互不阻断)

```
① cc-switch(若 useCC 且路由≠grok)   → §6.1
② Grok Build(若路由=grok)           → §6.4
③ CPA(若 useCPA)                    → §6.2,随后立即做 CPA 常驻同步
④ DSH(若 useDSH 且含 deepseek 系模型) → §6.3
⑤ 历史账本落盘 + 探测点入监控
```

每步独立 try/catch:某一步失败只在结果里记"✗ xx 失败",不影响其他目标。**开关来源**:CLI/UI 覆盖参数 > `prefs.json`(默认 useCC=开、useGrok=开、**useCPA=关**、useDSH=开、cpaResident=开)。

### 阶段 7:结果反馈
每条目标一行结果(✓/✗ + 提示),同时写入 KeyDrop 日志;这是排查"到底导入了什么"的第一现场。

---

## 4. 模型、路由矩阵:"这个 key 该进 Context 还是 Claude Code?"

### 4.1 体系内没有叫 "Context" 的写入目标

KeyDrop 的写入目标是**固定的这几个**:Claude Code、Codex CLI、OpenCode、Grok Build、CPA、DSH(另有 pi/openclaw/hermes 仅经 CPA 常驻间接覆盖)。
- 你说的 **Context 如果是指 OpenAI Codex CLI** → gpt 系模型自动路由进 codex,见下表;
- 如果是**其他 OpenAI 兼容客户端**(自填 baseURL+key 的那种)→ KeyDrop 不直写它,正确姿势是让它指向 `http://127.0.0.1:8317/v1` + CPA 客户端 key(经 CPA 消费所有已导入 key),或从 KeyDrop 条目里复制原 key 手填。

### 4.2 路由矩阵(模型家族 → 目标 App)

路由只看**最终选中的模型列表**,判定顺序即优先级(`routeAppType`):

| 顺序 | 条件(对选中模型列表) | 路由到 | 理由 |
|---|---|---|---|
| 0 | 用户显式 `--app`(UI 里强制指定) | 指啥是啥 | 唯一例外:`--app grok` 但列表不全是 grok 系 → 降级 opencode(安全规则) |
| 1 | **全部**是 grok 系 | **Grok Build** | grok 家族专用配置结构 |
| 2 | 混入 grok(但非全) | **OpenCode** | 混家族不能进 Grok 专用结构 |
| 3 | 含 **claude 系**(id 含 claude/sonnet/opus/haiku/fable) | **Claude Code**(cc-switch claude 类型) | claude 系必须进 Claude 生态 |
| 4 | 含 **gpt 系**(gpt 后跟数字/-oss,如 gpt-5、gpt-oss;gpt-image 不算) | **Codex CLI**(cc-switch codex 类型) | Codex 仅支持 gpt 家族 |
| 5 | 其他(deepseek/qwen/kimi/glm/mimo…,含 deepseek 系额外写 DSH) | **OpenCode**(cc-switch opencode 类型) | 通用 OpenAI 兼容客户端 |

补充规则:
- **deepseek 系双写**:路由通常是 opencode,但只要选中模型里有 deepseek 系,DSH 也会写入(§6.3)。
- **default**:用户在 UI 设置里选的默认 App(`KEYDROP_APP`,默认 opencode)——列表为空时的兜底。
- **激活模型**:写入时挑 chat 家族的第一个当默认;纯图生/嵌入类永不激活,但会出现在可选列表里。

### 4.3 典型例子

| 贴入的网关模型列表 | 路由 | 实际写入 |
|---|---|---|
| claude-opus-5-5, kimi-k3, deepseek-v4.1-flash | claude(含 claude 系) | cc-switch→Claude Code;DSH(deepseek);CPA(若开) |
| gpt-6-sol, gpt-6-astra | codex(全 gpt 系) | cc-switch→Codex;CPA(若开) |
| grok-4.6 | grok | Grok Build |
| kimi-k3, glm-5.2 | opencode | cc-switch→OpenCode;CPA(若开) |

---

## 5. cc-switch 写入详解(§6.1)

### 5.1 写什么
- **DB**(`cc-switch.db`):新 provider 行(含全部 env/模型配置)`is_current=1`、其余同类型行置 0、`sort_index` 抢到最前;`provider_endpoints` 记录端点 URL。
- **激活指针**:`settings.json` 的 `currentProviderClaude/Codex/Opencode` = 新 provider id。
- **live 配置一致性写入(v1.4.29 起)**:无论 cc-switch 是否运行,导入即把 live 文件同步写成与 DB current 相同的 env。这样 cc-switch 自身的"live→DB 回写"无论何时触发、命中哪一行,写回的都是该行自己的配置,**退化为 no-op**——两类回写污染事故同时关死。
  - 例外:`PROXY_MANAGED`(cc-switch 本地代理接管中,live 指向 15721)绝不直写。

### 5.2 各 App 类型的配置形态
| App | settings_config 内容 | 模型键规则 |
|---|---|---|
| claude(Claude Code) | `env.ANTHROPIC_AUTH_TOKEN/BASE_URL` + ANTHROPIC_MODEL 系列键 | 只写 claude 系模型;列表无 claude 系则省略模型键(回退默认) |
| codex | TOML `base_url` + auth token + model 行;先探测 Responses API 支持性(openai_responses / openai_chat) | 只写 gpt 系 |
| opencode | DB 配置 + **opencode.json 双写**(同一份 modelDict 防漂移) | 激活模型 = chat 家族优先 |

### 5.3 去重与共存(cc-switch 侧)
| 情形 | 行为 |
|---|---|
| 同 URL + 同 key 重复导入(opencode/codex) | 删旧建新(幂等) |
| 同 URL + **不同** key | **共存**,绝不删旧(旧凭据可能还活着) |
| 家族变化的重导入(如 claude→codex) | 先建新类型 provider,成功后才删旧类型(可回退) |

### 5.4 排序
新 provider 的 `sort_index=0`,旧的顺延——cc-switch 列表里最新导入的排最前且是激活态。

---

## 6. CPA 写入详解(§6.2)——"我的 key 是怎么导入 CPA 的?"

### 6.1 单 key 的完整链路
1. KeyDrop 在 CPA `config.yaml` 的 `openai-compatibility:` 段下定位(或新建)一个**聚合条目**,`name = 域名[:端口]`(如 `sub.tidalrelay.com`)。
2. key 并入该条目的 `api-keys` 列表(同 baseURL 多 key 归一组,**CPA 运行时组内轮询、失效自动剔除**)。
3. 模型列表写入该条目的 `models` 段(`- name:` 列表项)。
4. **精选保护**:条目已有非空 models = 用户精选 → 只合 key 不动模型;条目 models 为空(上次探测失败)→ 补写本次探测结果。
5. CPA 运行时会**自动热重载** config.yaml,无需重启。

### 6.2 多 key 链路
- 仅多 key 批量粘贴可用(useCPA 必须开);每把 key 并发探测(上限 4),**只剔除明确 401/403 的失效 key**,超时/429/5xx 保留(避免暂时故障误删)。

### 6.3 消费链路(别人最常问的"那我怎么用?")
```
任意工具(opencode/pi/手填 baseURL 的客户端)
        │  baseURL = http://127.0.0.1:8317/v1
        │  apiKey  = CPA 的客户端 key(config.yaml 里的 api-keys,不是上游 key!)
        ▼
   CPA 本地服务 → 按请求里的 model 名路由到聚合条目 → 组内轮询某把上游 key → 上游网关
```
- **上游 key 永远不出现在消费方**,轮询/失效切换由 CPA 托管。
- 直连 key 与 CPA 是**并存**的两条通道:history 条目始终保留原始 url+key,CPA 只是额外的消费层。

### 6.4 CPA 常驻入口(被动,绝不抢激活)
每次 CPA 导入成功后(或手动 `keydrop cpa-sync`)自动同步,模型来源 = 本次条目精选或遍历所有 cpa 条目的精选并集,**绝不拉 CPA 聚合 /models 全量**(真实反馈:聚合全量混 22 家上游 100+ 模型):

| 目标 | 行为 |
|---|---|
| cc-switch-opencode | 双写 DB+opencode.json,名字 `CPA·127.0.0.1:8317`,`is_current=0`(被动入口不抢激活);恰为当前激活才设默认模型 |
| cc-switch-pi / openclaw / hermes | 仅该类型在 cc-switch 已有 provider 行(=你在用)才写;pi 用固定托管行 upsert,openclaw/hermes 已有你手写的该端点配置则跳过不覆盖 |
| DSH | 已装才写;有你手写 route → 不动;否则幂等写 `keydrop-cparesident` |
| cc-switch-claude / codex | **不放**(反代封杀严),只清理历史误建行(激活态的拒绝自动删) |

### 6.5 两种写入模式
- **文件模式**(默认):FileLock + 原子写直接改 config.yaml。
- **API 模式**(设置了 CPA 管理密钥):全部读写走 CPA 管理 API,不触碰数据目录文件(根治 macOS TCC"文稿"弹窗)。

---

## 7. DSH 写入详解(§6.3)

- **触发条件**:useDSH 开 且 选中模型含 deepseek 系(或解析出的主模型是 deepseek)。
- **两文件、一个引用关系**:`settings.yaml` 的 provider 块 `apiKeyEnv: KEYDROP_<ID前8位>_API_KEY` → `.credentials.yaml` 的 `refs:` 映射里同名键存真实 key。
- **凭据文件格式铁律(dsh 解析器强校验)**:顶层仅允许 `version`/`refs`,凭据必须缩进嵌在 `refs:` 内。顶层裸写 → dsh 启动即崩(v1.4.30 修复的事故,见 §10)。
- 写入顺序:credentials 先、settings 后(反过来失败会留下"引用不存在凭据"的半成品)。

---

## 8. Grok Build / Clash / 生图(简)

- **Grok Build**:路由 = grok 时,按模型逐段 upsert(baseURL+key+模型名),移除已勾掉的旧模型段;Grok 的偏好只管**新导入**,存量条目刷新时仍留在原处。
- **Clash**:粘贴代理节点行或订阅链接 → 写 mihomo-party profiles 目录;与 key 导入互斥(自动识别)。
- **生图(`image-add`)**:生图 key 写**独立**的 CPA 聚合条目(`name = host:port-image`,models 带 `image: true`),与文本条目分开——防止图生模型混进文本精选、文本精选污染生图常驻。

---

## 9. 优先级与"绝不覆盖"总表

| # | 规则 | 说明 |
|---|---|---|
| 1 | 显式指定 > 家族自动路由 > 默认 opencode | `--app`/UI 强制指定最优先(唯一例外:grok 安全降级) |
| 2 | 同 key 同 URL = 幂等更新;同 key 异 URL = 报错;同 URL 异 key = 共存 | 以 history 账本判定 |
| 3 | CPA 精选模型 > 探测全量 | 已有精选只合 key;`refresh` 的整体替换是唯一例外(用户重新勾选 = 重新确认) |
| 4 | picker 勾选结果不再过启发式去噪 | 勾的就是真实 /models id |
| 5 | 常驻入口被动:`is_current=0` | CPA·127.0.0.1:8317 永不抢激活 |
| 6 | 用户手写配置绝不覆盖 | openclaw/hermes 手写端点、DSH 手写 route、cc-switch 里手改的 key/网关 |
| 7 | 自愈签名极窄 | 回写污染自愈只认「loopback 地址 + CPA clientKey」同时命中;手改 key/换网关一律不碰 |
| 8 | 非 chat 模型永不激活 | 图生/嵌入/语音只进可选列表 |
| 9 | 写入失败绝不记 tag,删 tag 前必删成功产物 | 账本不变量,保证可对账可清理 |
| 10 | 多 key 只进 CPA | 单文件目标(cc-switch 等)装不下多凭据轮询 |

---

## 10. 生命周期:刷新 / 删除 / 对账 / 自愈

### 刷新(refresh 按钮 / `keydrop refresh`)
1. 重新测试(直连→代理),弹窗重新勾选模型(picker 用原始 /models 列表,不过滤)。
2. cc-switch:DB settings_config **总是**更新;该 provider 是 current 时同步 live。
3. CPA:聚合条目 models 段**整体替换**(refresh = 用户对列表的重新确认,取消勾选的要真删)。
4. 家族变化 → 自动迁移:不匹配的旧 provider 删除重建(entry 的 targets/ccProviderID 同步改)。
5. 探测结果写入监控时间轴(健康页的图)。

### 删除
逆序清理所有产物:cc-switch provider → Grok 段 → CPA key → DSH route+凭据 → live 回退(防陈旧配置复活)。tag 只在产物删成功后摘除。

### 对账(每小时健康扫描前 + 应用启动 self-heal)
- history 里 active 且带 ccswitch tag,但 cc-switch 里 provider 已被删:
  key 已失效(401/403)→ 同步标记删除;key 仍可用 → 标记 `ccMissing` 待手动重导(不自动复活)。
- **回写污染自愈(v1.4.29)**:KeyDrop 托管的 claude 行若命中「baseURL 是 loopback 且 key == CPA clientKey」(= 被陈旧本地代理环境整块回写覆盖的事故签名)→ 用条目 url/key 还原;手改 key/换网关不碰。
- **孤儿收养(v1.4.31)**:更新重启 kill 打断导入的毫秒级窗口会留下「产物在、账本无」的孤儿 provider(外部产物写入先于账本落盘)。对账凭 cc-switch 行 meta 里的导入标记识别(KeyDrop 写入的临时导入行才有;常驻入口/用户手写行无标记,永不触碰),从 provider 行重建账本条目**收养**之——配置是导入时已通过测试的完好凭据,收养后删除/刷新/对账恢复可用;key 已在账本时跳过并告警,绝不静默制造重复凭据。

### 健康扫描
连续失败 → `health=dead` → 移入"待删除区"(status 仍是 active,不会变成删不掉的僵尸);quota/auth 失效有独立标注。

---

## 11. FAQ(别人视角的常见问题)

**Q1:我这个 key 是怎么"导入 CPA"的?它会拿我的 key 去干嘛?**
A:KeyDrop 在 CPA 的 config.yaml 里建/合并一个以网关域名命名的聚合条目,把你的 key 放进它的 api-keys 组(同网关多 key 轮询),并写上精选模型列表。之后所有消费方只对接 `http://127.0.0.1:8317/v1` + CPA 客户端 key,你的上游 key 由 CPA 托管轮询,不暴露给消费方。原 key 仍完整保存在 KeyDrop 条目里,直连和经 CPA 是并存的两条通道。

**Q2:这个模型应该导入 Context 还是 Claude Code?**
A:体系里没有叫 Context 的目标。路由只看模型家族:claude 系(含 sonnet/opus/haiku/fable)→ Claude Code;gpt 系(gpt-5/gpt-oss 等)→ Codex CLI;grok 全家族 → Grok Build;其他(qwen/kimi/glm/deepseek…)→ OpenCode;deepseek 系额外写 DSH。你想强制指定用 `--app`(grok 有安全降级)。若是某个自填 baseURL 的第三方客户端(不管叫什么),让它指向 CPA 的 127.0.0.1:8317 即可。

**Q3:为什么这条 key 的 targets 里有 cpa、ccswitch、dsh 好几个?**
A:每个 tag 对应一个真实写入的产物。开关开着且条件命中(如含 deepseek → dsh)就会多写一处;多写是设计行为,删除时会被一起清理。

**Q4:模型列表为什么和网站上的不一样/少几个?**
A:五个可能:① 你在弹窗里只勾了部分;② 限流/配额模型被排除或沉底;③ 贴入文本里的模型 chat 验证失败被剔除(回落站点目录);④ CPA 精选保护(首次确认后再导入不回填全量);⑤ 家族过滤(如 Claude Code 只写 claude 系)。

**Q5:为什么 cc-switch 里有个叫 `CPA·127.0.0.1:8317` 的 provider?**
A:那是 KeyDrop 自动建的"CPA 常驻入口",让 opencode/pi 等工具免配置消费 CPA 后面的所有 key。它是被动的(is_current=0),不会抢你当前激活的 provider,可以随时在 cc-switch 里手动切换使用。

**Q6:127.0.0.1:8317 是什么?谁在跑?**
A:CPA(CLIProxyAPI)的本地服务端点。它按模型名把请求路由到 config.yaml 里对应的聚合条目(你的各个上游 key),负责轮询、失效剔除、热重载。

**Q7:key 失效了会发生什么?**
A:KeyDrop 健康扫描探测 401/403 → 标 dead 进"待删除区";CPA 聚合组内的 key 也会在探测失效后被自动剔除(只剔 401/403,超时/429/5xx 保留)。

**Q8:我在 cc-switch 里手动改了 provider 的配置,会被 KeyDrop 覆盖吗?**
A:不会。KeyDrop 只在**你主动导入/刷新对应条目**时更新它写入的行,且对账自愈的签名极窄(loopback+CPA clientKey 才判定为污染)。手改 key(比如站方轮换)、换网关都会被尊重。

**Q9:只贴了 key 没贴 URL,导入到哪了?**
A:复用上一次导入的 URL(结果里有"URL 复用上次"提示);首次导入必须带 URL。

**Q10:导入结果里的"直写模式/代理模式/已写入 cc-switch 数据库"是什么意思?**
A:live 配置文件的三种落法:直写=已同步写 live 文件(新会话即生效);代理=cc-switch 本地代理接管中,KeyDrop 不碰 live;DB-only 提示 v1.4.29 起只会在 live 文件不可读/非 JSON 等异常边角出现——正常情况下 claude 导入总是 live 一致性写入。

---

## 12. 事故与修复档案(为什么现在是这样)

| 版本 | 事故 | 修复 |
|---|---|---|
| v1.4.29 | 导入 sub.tidalrelay 后,cc-switch provider 的 baseURL/key 被 `127.0.0.1:8317` + CPA key 整块覆盖。根因:cc-switch 运行时 KeyDrop 只写 DB 不写 live,留下「DB current=新行,live=旧环境」漂移;用户激活新 provider 时 cc-switch 按数据库 `is_current` 把过期 live 回写进新行 | **live 一致性写入**:导入/刷新即把 live 写成与 DB current 相同 env,回写退化为 no-op;对账新增回写污染自愈(loopback+clientKey 签名) |
| v1.4.30 | 同一次导入,DSHWriter 把 `KEYDROP_07FA1C9C_API_KEY` 顶层裸写进 `.credentials.yaml`(dsh 要求凭据嵌在 `refs:` 内)→ dsh 启动崩溃。外部 AI 只手工缩进了文件,但写入方不感知 refs,下次写入会再追加顶格重复行 | **refs 感知写入**:凭据一律缩进写进 refs 块末尾(多行标量安全)、顶格遗留自愈清除、空文件落骨架、删空收敛 `refs: {}` |
| v1.4.31 | 更新重启确认后 `kill -9` 无业务任务校验:导入流程"外部产物已写、账本未记"的毫秒级窗口被杀会留下孤儿 provider。影响面评估:监控数据采集不受影响(探测点逐条即时落盘)、各文件均有原子写/事务保护;唯一缺口是孤儿 | **孤儿收养**:cc.add 在 provider 行 meta 写入导入来源标记;对账时未认领的带标记行从行内重建账本条目(收养而非删除),key 重复时跳过告警 |

---

## 附:排查一条 key 的入口清单

1. `~/.keydrop/history.json` → 找条目:看 `targets`(写了哪些产物)、`models`(精选列表)、`health/healthDetail`(探测详情)、`note`(导入过程记录)。
2. `~/Library/Logs/KeyDrop/keydrop.log` → 搜条目 id 前 8 位:完整的导入/刷新/对账流水。
3. cc-switch:`sqlite3 ~/.cc-switch/cc-switch.db "SELECT name,settings_config FROM providers WHERE id LIKE 'xxx%'"`。
4. CPA:config.yaml 搜聚合条目名(网关域名)。
5. DSH:`~/.dsh/settings.yaml` + `~/.dsh/.credentials.yaml`(确认凭据在 `refs:` 内)。
