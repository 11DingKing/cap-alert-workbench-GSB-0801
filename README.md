# CapAlertWorkbench — 公共预警编审工作台

暴雨 / 强对流等公共预警（CAP 1.2）的编审工作台：草稿编辑 → 提交复核 → 复核 → 发布，
发布后内容冻结不可修改，后续变更只能基于已发布版本发起**更正（Update）**或**解除（Cancel）**。

技术栈：Elixir 1.20 / OTP 29、Phoenix 1.8、Phoenix LiveView、Ecto + PostgreSQL 17。

## 架构约定

| 层 | 模块 | 职责 |
| --- | --- | --- |
| 领域层 | `CapAlertWorkbench.Cap.Enums` | CAP 枚举的显式双向映射（模式匹配，拒绝未知值） |
| 领域层 | `CapAlertWorkbench.Cap.Lifecycle` | 草稿/消息流状态机（显式枚举转换，非法转换返回错误） |
| 领域/服务层 | `CapAlertWorkbench.Cap.Xml` 等 | CAP XML 序列化/解析（Saxy + XmlBuilder，无字符串拼接，拒绝 DOCTYPE/外部实体） |
| 用例层 | `CapAlertWorkbench.Alerts` | 全部公开用例；LiveView 与 API 只能调用它，不得直写状态字段 |
| 表现层 | `CapAlertWorkbenchWeb.WorkbenchLive` / `Api.MessageController` | 页面与 REST API |

一致性保证：

- **乐观锁**：草稿版本携带 `lock_version`，过期提交返回 `stale_lock`（409）。
- **复核防竞态**：复核结论钉住 `pinned_lock_version`，复核期间草稿被修改则结论失效，返回 `stale_review`。
- **发布**：单事务内完成 行级锁 → 最新版本检查 → 工作流守卫（approved→published）→ 冻结 CAP XML（不可变 `published_documents`）→ 消息流状态机转换 → 审计事件 → 通知 outbox；任一步失败全部回滚。重复发布返回 `already_published`，未复核返回 `not_publishable`。
- **更正/解除**：仅当消息流处于 `published` 且基于最新已发布文档创建，CAP `references` 自动指向上一发布文档；同一消息流同时只允许一个未发布草稿（部分唯一索引兜底）。

## 启动

前置：PostgreSQL 已启动且存在 `postgres`/`postgres` 账号（可用 `CREATE ROLE postgres LOGIN PASSWORD 'postgres' SUPERUSER;` 创建）。

```bash
mix setup          # 依赖 + 建库 + 迁移 + 种子数据 + 资产构建
mix phx.server     # 或 iex -S mix phx.server
```

访问 <http://localhost:4000> 。种子数据包含初始预警 `CN-20260729-GD-RAIN-001`
（Actual / Alert / Public / zh-CN / Immediate / Severe / Likely，地区编码 440800、440900），
初始为「编辑中」草稿。

## 常用命令

```bash
mix format        # Mix 原生格式化
mix test          # 自动化测试（含并发竞速、事务回滚、XML round-trip/XXE 用例）
mix assets.build  # 资产构建（tailwind + esbuild）
mix precommit     # compile --warnings-as-errors + format + test
mix ecto.reset    # 重建数据库并重新灌入种子
```

## REST API

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/streams` | 消息流列表 |
| GET | `/api/streams/:id` | 详情（版本/发布文档/审计/outbox） |
| POST | `/api/versions/:id/draft` | 保存草稿（需 `lock_version`） |
| POST | `/api/versions/:id/submit-review` | 提交复核 |
| POST | `/api/versions/:id/review` | 复核（`decision` + `pinned_lock_version`） |
| POST | `/api/versions/:id/publish` | 发布 |
| GET | `/api/versions/:id/cap.xml` | 导出 CAP XML |
| POST | `/api/streams/import` | 导入 CAP XML（body 为 XML 原文） |
| POST | `/api/streams/:id/corrections` | 发起更正 |
| POST | `/api/streams/:id/cancellations` | 发起解除 |

错误统一返回 `{"error": {"code": ..., "message": ...}}`，机器可读码包括
`stale_lock`、`stale_review`、`already_published`、`not_publishable`、`not_latest_version`、
`draft_already_exists`、`identifier_taken`、`invalid_transition`、`doctype_forbidden`、`malformed_xml`、`unknown_enum`。

## 双浏览器验证冲突

开两个浏览器窗口打开同一消息流：

1. 两边同时编辑草稿后先后保存 → 后保存方收到「乐观锁冲突」提示并自动刷新；
2. 提交复核后，编辑者继续改稿，复核人再点「复核通过」→ 旧结论失效（`stale_review`）；
3. 复核通过后两边同时点「发布」→ 仅一次成功，另一个收到「该版本已发布」；
4. 页面状态、不可变版本、审计事件、通知 outbox 通过 PubSub 实时保持一致。
