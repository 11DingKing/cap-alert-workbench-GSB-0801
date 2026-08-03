# CAP 预警编审工作台

基于 Phoenix LiveView 的 [Common Alerting Protocol (CAP) 1.2](https://docs.oasis-open.org/emergency/cap/v1.2/CAP-v1.2-os.html) 预警草稿、版本差异、复核与发布工作台。

* 草稿编辑（乐观锁防止并发覆盖）
* 版本历史与逐字段差异对比
* 提交 → 复核（通过/退回）→ 发布的状态机
* 发布后内容不可变，仅可创建更正（Update）或解除（Cancel）
* 审计事件 + 事务性 Outbox（发布与通知原子提交）
* CAP XML 导入/导出（命名空间、扩展字段、特殊字符转义、XXE 防护）
* JSON REST API

## 技术栈

* Elixir / Phoenix 1.8 / LiveView
* PostgreSQL（`SELECT ... FOR UPDATE` 行锁 + `SKIP LOCKED`）
* `:xmerl` 解析 XML，`xml_builder`（通过 `XmlBuilder`）序列化

## 快速开始

```bash
# 安装依赖、创建并迁移数据库
mix setup

# 写入初始预警 CN-20260729-GD-RAIN-001
mix run priv/repo/seeds.exs

# 启动服务
mix phx.server
```

打开 <http://localhost:4000>。

初始消息：

| 字段 | 值 |
| --- | --- |
| identifier | `CN-20260729-GD-RAIN-001` |
| sent | `2026-07-29T08:00:00Z` |
| status / msgType / scope | `Actual` / `Alert` / `Public` |
| language | `zh-CN` |
| urgency / severity / certainty | `Immediate` / `Severe` / `Likely` |
| geocodes | `Same:440800`, `Same:440900` |

## 测试与质量检查

```bash
mix test          # 46 个测试
mix precommit     # 编译（warnings-as-errors）+ 资源构建 + 测试
mix format
```

## 架构要点

### 状态机（`CapAlertWorkbench.CapAlert.StateMachine`）

所有状态转换通过模式匹配显式声明，LiveView/API 不得直接写 `workflow_state`：

```
draft ──submit──▶ in_review ──approve──▶ approved ──publish──▶ published
                     │                       │
                   reject                  (旧版本在 Update/Cancel 发布后变为 superseded)
                     ▼                       │
             changes_requested ◀────────────┘
```

* 只有“最新版本”可以被复核/发布；作者在复核期间新建草稿后，旧的复核结论会被拒绝（`stale_review`）。
* 发布时使用 `SELECT ... FOR UPDATE` 锁定 alert 与 version 行；重复发布由状态机 + 行锁共同保证只有一个成功。

### 乐观锁（`AlertVersion.lock_version`）

草稿表单携带隐藏的 `lock_version`。提交时 `Ecto.Changeset.optimistic_lock/3` 生成
`UPDATE ... WHERE lock_version = ?`；若另一浏览器已先保存，则影响 0 行并返回 `:stale`，页面显示冲突提示。

### 事务性 Outbox

`publish/2` 在单个事务中完成：版本状态更新、CAP XML 快照生成、旧版本更迭、
审计事件写入、`notification_outbox` 写入。事务中途失败会整体回滚（见 `simulate_publish_failure` 配置用于混沌测试）。
独立的 `OutboxPublisher` 进程用 `FOR UPDATE SKIP LOCKED` 拉取待发记录并通过 PubSub 广播。

### CAP XML 安全

* 解析前拒绝任何含 `<!DOCTYPE` / `<!ENTITY` 的文档（XXE 防护）。
* 序列化基于 XML 数据结构而非字符串拼接，`<`, `>`, `&`, `"`, `'` 自动转义。
* 未建模的 CAP 元素（如 `code`、命名空间扩展）作为扩展字段原样保留，支持往返。

## API

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/alerts` | 列表 |
| POST | `/api/alerts` | 创建草稿 |
| GET | `/api/alerts/:identifier` | 详情（含版本、审计、outbox） |
| GET | `/api/alerts/:identifier/versions/:id/cap` | 导出 CAP XML |
| POST | `/api/alerts/:identifier/versions/:id/submit` | 提交复核 |
| POST | `/api/alerts/:identifier/versions/:id/review` | `decision=approve|reject` |
| POST | `/api/alerts/:identifier/versions/:id/publish` | 发布 |
| POST | `/api/alerts/:identifier/corrections` | 创建更正草稿 |
| POST | `/api/alerts/:identifier/cancellations` | 创建解除草稿 |
| POST | `/api/import` | body: `xml=<CAP XML>` |

请求可带 `X-Actor` 头标识操作者（写入审计）。

## 目录结构

```
lib/
  cap_alert_workbench/
    cap_alert.ex              # 公开用例边界（LiveView/API 唯一入口）
    cap_alert/
      state_machine.ex        # 纯状态机
      cap_xml.ex              # CAP XML 解析/序列化
      alert_version.ex        # Ecto schema（含乐观锁）
      outbox_publisher.ex     # 事务性 outbox 消费者
  cap_alert_workbench_web/
    live/                    # LiveView：列表、新建、工作台、复核、差异
    controllers/api/         # JSON/XML API
```
