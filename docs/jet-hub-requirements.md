# Jet Hub / Cordis 功能需求:Provider 搜索与状态

## 背景

KeyDrop 将 provider 同步到 DSH(通过 `settings.yaml` 和 Cordis profile 补丁层),
Jet Hub 的「模型」设置页展示这些 provider。当前存在以下可用性问题:

1. **无法按名称或 key 搜索 provider**:provider 数量多时(20+),找到特定
   provider 需要逐个滚动查看,没有搜索框或过滤功能。
2. **无法按状态过滤**:用户想快速看到「哪些 provider 可用/异常/未测试」,
   当前只能逐个查看状态圆点。
3. **无排序选项**:provider 列表按添加顺序展示,不能按名称/状态/最近使用排序。

## Web 模型选择器

已核对本机 DSH 的模型选择器实现。筛选调用为
`rankByName(group.models, query)`，随后移除没有匹配模型的分组。
搜索只接收模型数据，provider 分组名和内部 ID 没有传入。即使 KeyDrop 已正确写入 provider，
仅输入站点名或 `keydrop-<id8>` 也无法找到它的模型。

建议在对话输入区的模型选择器中增加以下搜索字段，同时保留模型设置页的独立搜索需求。

- provider 显示名、内部 ID 和网关主机名。
- 模型显示名和完整模型 ID。
- 在搜索结果中展示 provider 来源。选择结果继续使用原始 provider ID 和模型 ID。

验收时创建两个提供同名模型的 provider。输入模型名应找到两组，输入其中一个
provider 的显示名、主机名或内部 ID 应只显示该组。搜索凭据引用时仅匹配和展示
`apiKeyEnv` 引用名，界面无需读取凭据值。

## 需求

### R1: Provider 搜索

在「模型」设置页顶部添加搜索框,支持:
- 按 provider 名称模糊匹配(不区分大小写)
- 按 baseURL 匹配
- 按 apiKeyEnv 匹配(方便从 KeyDrop 的 KEYDROP_XXX_API_KEY 定位)
- 实时过滤,无需回车

### R2: 状态过滤器

在搜索框旁添加状态过滤下拉(或标签筛选):
- 全部 / 可用 / 异常 / 未测试
- 状态来源:Jet Hub 自身的健康探测结果

### R3: Provider 排序

添加排序选项:
- 名称 A→Z / Z→A
- 状态(可用优先)
- 最近使用时间

### R4: Provider 名称可读性

KeyDrop 同步的 provider 名为 `keydrop-<id8>` 格式,不够直观。
建议:
- 支持 provider 别名/显示名(与内部 key 分离)
- 或在 provider 列表中同时显示 baseURL,方便识别

### R5: Provider 批量操作

支持:
- 批量删除选中的 provider
- 批量启用/禁用

## 优先级

R1(搜索)> R2(状态过滤)> R4(名称可读性)> R3(排序)> R5(批量操作)

## 关联

- KeyDrop 已在 Cordis 补丁层(`profiles/<name>/cordis.patch.yml`)写入
  `id: llm-pi-ai` 条目的 `config.providers`,Jet Hub 应保证补丁层中的
  provider 与 UI 展示同步
- KeyDrop 的 reconcileDSH 会自动清理孤儿路由,Jet Hub 的存储应跟随
