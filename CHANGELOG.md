# 更新日志

## 未发版(当前构建,基于 1.4.60)

### DSH / Jet Hub 生命周期对账体系(与 cc-switch 拉平)
- `reconcileDSH` 四层对账:孤儿路由清理(连同凭据)/ 认领路由漂移重写(baseURL/models 以账本为准)/ 凭据缺失自愈 / 缺失只报告不自动重建(尊重 DSH 界面手删)
- Cordis 补丁层(`profiles/**/*.patch.yml`)只读检测:残留的 keydrop-* 路由点名警告;第三方私有层 KeyDrop 绝不改写
- 接入启动 self-heal、每次「同步到 DSH」自动全量对账;新增 CLI 命令 `KeyDrop dsh-reconcile`
- 守恒断言:同步两次路由数 == 账本认领数;漂移/自愈/缺失/补丁层场景回归

### 复制按钮升级:主操作 + 下拉
- 行内 curl 按钮:点击仍复制 curl(原行为);长按/点下拉可选复制
  BaseURL / API Key / 模型名(模型名按条目逐一列出,复制的是
  copyModelName 规整后的名字,与模型行的复制一致)

### DSH 路由名可读化
- 路由名从 `keydrop-<id8>` 升级为 `keydrop-<id8>-<站点>-<首选模型>`(如
  `keydrop-378755c6-abc.com-deepseek-v4.1-flash-1017`),DSH 界面一眼可见是什么渠道;
  唯一键仍是 id8,删除/对账按前缀家族认领,url/models 变化时自动摘旧名挂新名(改名而非残留)
- KeyDrop 面板行 hover 提示全面重写:URL/模型清单/key 掩码/健康详情/延迟/uptime/
  连败防抖/CPA 链路/真伪鉴定/写入目标/导入时间(行本身保持紧凑)

### 账本外部变更感知
- HistoryStore 监听账本目录:CLI / 另一进程 / WebDAV 拉取写入后,打开中的面板自动刷新(0.4s 合并去抖)
- 此前面板只在「本进程操作后」刷新,外部写入要手动点什么才可见

### 并发治理:协作线程池去阻塞
- 新增 `runOffPool` 助手,把可能长时间阻塞的同步调用统一挪出 Swift 协作线程池
  (宽度≈CPU 核数):导入等待用户选模型(最长 120s)、健康扫描(数分钟)、
  真伪鉴定(7×40s)、WebDAV 推拉、订阅拉取等全部迁至 GCD 工作线程
- 此前两个长阻塞各占死一个协作线程即可能饿死其它后台任务(拖拽读取/WebDAV 定时器)
- 取消语义与原 Task.detached 一致:外层取消后 GCD 闭包跑完,不中断

### 探测时长治理与 CPA 校验去重
- 连接层不可达(DNS 失败/拒连/离线/TLS 失败)时立即短路同 host 的备用路径与协议回退:
  离线/主机不存在场景单 key 探测曾最坏串行 13 个请求 ≈ 220s,现在一个请求即出结论;
  读超时仍保留多路径重试(单端点挂死时另一路径可能可用)
- CPA YAML 校验按内容哈希缓存:同一内容只 spawn 一次 python;新内容改为「先验后写」,
  无效 YAML 不再有落盘窗口,原「写后校验失败回滚」机制随之移除(.keydrop-bak 仍保留)

### 协议持久化与限流冷却
- 账本可选 `apiStyle` 字段(缺字段旧记录兼容):导入/刷新/巡检保存协议,跨进程复用已确认协议
- chat 健康探测遇 429/402 + 有效 Retry-After 时,按 地址/凭据/模型/代理 隔离冷却(秒数与 HTTP 日期,上限一天,重启清除)

### 解析与导入修复
- 裸域名带路径/端口的 URL 识别(`tokenhub.icu/v1`、`gw.example.com:8317/v1`);漏判时禁止静默复用上次 URL(防拿新 key 测旧站),失败报错附复用说明
- Clash 订阅 YAML 自引入起即非法的问题(字段缩进错位),同名节点去重防 mihomo 拒载

### 深度审计修复(8 项 P1 + 20 项 P2,含但不限于)
- HistoryEntry.encode 漏 deletedAt/updatedAt/verifyVerdict:修复多设备同步 LWW、墓碑计龄、鉴定结论持久化
- `--force` 覆盖同 key 异 URL 不再静默丢弃新 URL
- CPA 聚合条目:缺 api-key-entries 段补建;同 host 异 path 分条目(不再错路由)
- codex:无空格 `model="x"` 不再产生重复键;custom 段缺失键补写;合并全程加锁
- chat 探测网络错误(超时)不再误判「可用」;真伪鉴定长推理不再被 session 超时截断
- Prefs.save 锁外读 WebDAV 字段竞态;opencode.json/claude settings 0600;curl 探测凭证不再进 argv
- make-app.sh 安装后清理 dist 构建产物(Spotlight 双 app)

## v1.4.60
- 修正 1.4.59 发版时 Info.plist 被并发回写为 1.4.58

## v1.4.59
- 同步菜单补齐四目标(cc-switch/CPA/DSH/Grok)
- 真伪鉴定结论持久化到条目

## v1.4.58
- 真伪鉴定入口提到 provider 列表行,按需点击、弹窗展示

## v1.4.57
- 模型真伪鉴定:能力阶梯探针(数学/计数/逻辑分级实测),实测层级 vs 声称层级不符 → 高概率模型替换提示

## v1.4.55 / v1.4.56
- 编辑框 ⌘Z 撤销 / ⇧⌘Z 重做
- 删除守卫只拦 current provider;刷新失败仍可重新勾选模型
