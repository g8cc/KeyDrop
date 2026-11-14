# 更新日志

## v1.4.61

含自 v1.4.60 以来的全部修复:同步链路专项加固(17 项审计发现)、
更新包清单校验修复(旧版自动更新全部被拒的根因)、DSH 全生命周期对账、
Magpie 渠道支持、监控诚实化、真伪鉴定每模型结论、解析修复等。
详尽变更见下文各节(此前标题为「未发版」)。

### DSH / Jet Hub 生命周期对账体系(与 cc-switch 拉平)
- `reconcileDSH` 四层对账:孤儿路由清理(连同凭据)/ 认领路由漂移重写(baseURL/models 以账本为准)/ 凭据缺失自愈 / 缺失只报告不自动重建(尊重 DSH 界面手删)
- Cordis 补丁层(`profiles/**/*.patch.yml`)只读检测:残留的 keydrop-* 路由点名警告;第三方私有层 KeyDrop 绝不改写
- 接入启动 self-heal、每次「同步到 DSH」自动全量对账;新增 CLI 命令 `KeyDrop dsh-reconcile`
- 守恒断言:同步两次路由数 == 账本认领数;漂移/自愈/缺失/补丁层场景回归

### 复制按钮升级:主操作 + 下拉
- 行内 curl 按钮:点击仍复制 curl(原行为);长按/点下拉可选复制
  BaseURL / API Key / 模型名(模型名按条目逐一列出,复制的是
  copyModelName 规整后的名字,与模型行的复制一致)

### DSH 同步可见性说明(重要机制澄清)
- `settings.yaml` 是 DSH web(Jet Hub)的「启动时导入通道」:web 进程启动时
  把它合并进自己的 profile 存储(随后改名 .imported),运行中不读该文件。
  KeyDrop 同步写入成功后,需**重启 DSH web** 才能在 Jet Hub 界面看到——
  同步结果与对账报告现在会如实提示(dsh web 运行检测)
- 此前对账报告的「N 个已同步路由缺失」多为已被 Jet Hub 采纳进其存储的
  路由(settings.yaml 被消费掉了),无需逐个重新同步

### 新增第三方工具支持:Magpie(yetone/magpie)
- 行内「同步到…」菜单新增 Magpie:经其 Web 管理 API 创建/更新 provider
  (?k= Cookie 登录 → /api/provider/save),写入 名字(装饰名)/key/
  chat·responses·anthropic 端点(版本段挂载与协议根,与 all-api-hub 的
  channel-import 同语义)/模型勾选;二次同步原地更新,删除条目时调
  /api/provider/delete 清理
- 设置:菜单栏「Magpie 设置…」粘贴 Magpie 托盘的完整 Web 链接
  (http://host:port/?k=…),KeyDrop 自己拆地址与 key;Cookie 手动捕获
  回传(不依赖 CookieStorage 对 IP 主机的处理怪癖)

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

### 自动更新修复(严重)
- 更新包清单校验自 v1.4.34 起对任何真实更新包都会误拒:unzip -l 名称列的
  列对齐填充空格残留在名称里,顶层组件变成 "  KeyDrop.app" ≠ "KeyDrop.app"
  (真实事故:旧版升级报「顶层含非预期内容: KeyDrop.ap…」)。已修复并加
  真实资产清单回归测试。受影响的旧版本用户需手动安装一次(下载 dmg/zip
  拖入 Applications),之后的自动更新恢复正常

### 同步链路专项加固(双代理审计 17 项发现)
- **Grok key 轮换残留(P1)**:removeModelSections 按 model+key 寻址,换 key 后
  旧 key 的模型表永久残留并在 upsert 时制造 #尾号 重复表;sync/edit 现传
  staleKeys 清旧表
- **replayArtifacts 复活用户手删产物(P1)**:cc-switch 重建跳过 ccMissing 待确认
  条目;cc.add 新增 activate 参数,重放/同步不再抢激活(opencode 亦纳入),
  is_current=0、不改 switch settings 指针与 live 配置
- **feed LWW 三个越权(P1)**:本机墓碑不被远端 active 版复活;targets 取本机∪远端
  (曾整条取远端丢本地标签);墓碑传播现在按本机绑定清理产物(CPA 池 key/
  Grok/cc-switch,DSH 由孤儿清理自愈)
- **未装工具的机器不再被写入(P1)**:replay/feed 的 DSH/Grok 分支加安装守卫,
  不再凭空创建 ~/.dsh/~/.grok 并落明文凭据
- 口径与边界:reconcileDSH 与写入端统一 trim;managedRoutes 补转义解码
  (含引号/反斜杠的值曾每轮误判漂移无限重写);DSH 家族认领加 apiKeyEnv 校验
  (id8 碰撞不再互删);syncTarget 四分支补齐账本失败回滚;CPA 同步先回收
  旧路径 key 防双配置残留;常驻入口创建行打 keydrop 标记,用户手写的
  同端点行不覆盖(与 native 铁律同源);cpaResident 关闭后常驻路由正常回收
- reconcileWithCCSwitch 探测失败不再断言「key 仍可用」;401+HTML 盾页豁免
  与 403 对齐;applyCap 近期墓碑(60 天)豁免;账本指纹纳入 targets
  (targets 变更现在会触发自动推送)

### 真伪鉴定:每模型结论 + 修复丢失的结果弹窗
- **修复:鉴定结果弹窗从未挂载**——verifySheetShown 只被置位、从未渲染,
  跑完 6 次请求的鉴定明细无处可看(只剩盾形图标一个颜色)。现已挂载:
  弹窗含每模型结论一览、逐模型「鉴定」按钮、最近一次鉴定明细
- **多模型逐模型鉴定**:结论按模型持久化(verifyVerdicts),多模型条目
  可以逐个鉴定看清谁真谁假;盾形点击自动鉴定第一个未测模型
- 盾形 tooltip 全解:探测是什么(能力阶梯实测,随机算术/计数/逻辑题、
  程序判定、非指纹检测)、颜色语义(绿=实测达旗舰级;黄=实测中端/基础级,
  疑似模型替换/降级;红=基础任务失败,网关异常)、每模型结论列表
- 图标颜色补「异常=红」(原只有绿/黄两档)

### 监控诚实化:绿 ≠ 能用的三大窗口关闭
- **失败防抖分级**:服务端明确拒绝(401/403/429/5xx 等)第一次探测失败即降级;
  只对暂时性网络失败(超时/不可达)保留一次防抖。旧的一刀切防抖曾撑出最长
  2 小时的「全绿但访问完全不行」窗口(真实反馈)
- **防抖保留期可见**:保留期(首败未降级)状态点显示警示黄而非纯绿
- **CPA 链路失败行内可见**:经 CPA 网关(8317)的真实链路探测失败时行内显示
  「CPA 链路 ✗」徽章——上游直连是通的,但实际流量走的链路断了,此前只藏在 tooltip
- 监控频率(未变,供参考):面板每 60 分钟一轮扫描,只测「上次测试已超 30 分钟」
  的条目;每条每轮最多 4 个模型(激活置顶轮换);行内 ↻ 随时手动重测

### 终审修复(双代理全量再审)
- **死 key 永远显示"可用(需代理)"**:healthFor 把 needsProxy 排在 ok/authFailed
  之前,key 被吊销(双方 401)时仍返回 proxy-ok → 状态列永远绿;已修
- **feed LWW targets 并集是死代码**:迭代了远端数组而非本机数组,本机独有的
  DSH/CPA/Grok 标签整批丢失 → 下轮孤儿清理删路由+凭据;已修(迭代 local.targets)
- **墓碑传播脱离 LWW**:updatedAt 被健康扫描持续刷新,维护者的墓碑几乎永远
  传播不过来;远端有 deletedAt 且本机 active 时一律应用(不看时间戳)+ 清产物
- **syncTarget 四分支回滚销毁同步前就存在的产物**:统一加 alreadyHadTarget 守卫;
  ccswitch 分支补回滚
- **refreshModels/testEntry 成功时清 failStreak**:连败后手动救活,streak 残留
  导致下次瞬时失败直接降级
- MagpieWriter 登录 URL 强解包修复 + webKey 重编码;Cookie 捕获改进
- richTooltip 的 Int(latencyMs) 极端值钳制;displayRouteKey 截断尾 - 修复

### 解析与导入修复
- 内嵌 JSON 行提取:`{"_type":"newapi_channel_conn","key":…,"url":…}` 一行 JSON
  + 活动说明 + 可用模型列表 的粘贴,曾整段按多行文本切碎(key 变垃圾碎片、
  URL 被官方 fallback 误猜成 api.deepseek.com);现在正确提取并合并模型列表
- 模型候选剥尾部注解:`deepseek-v4.1-flash (会映射到deepseek-flash)` 曾整行
  因含空格被当非模型而丢失;`[日期]` 开头的活动标题行不再混进模型候选
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
