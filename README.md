# CAP 预警编审工作台 (CapWorkbench)

值班人员将暴雨 / 强对流处置建议编成结构化的公共预警（CAP 1.2），经复核后发布；
发布后的内容**不可修改**，只能基于已发布版本创建**更正 (update)** 或**解除 (cancel)** 消息。

技术栈：**Elixir/OTP · Phoenix · Phoenix LiveView · Ecto · PostgreSQL · Saxy (CAP XML)**。

---

## 1. 架构与约束

领域 / 服务层与 Web 层严格分离，LiveView 与 HTTP 控制器**只调用公开用例**，
从不直接改状态字段、也不直接访问 `Repo`：

| 层 | 模块 | 职责 |
|----|------|------|
| 枚举（唯一真源） | [`CapWorkbench.Cap.Enums`](lib/cap_workbench/cap/enums.ex) | 所有受约束的 CAP 值（status/msgType/scope/category/urgency/severity/certainty）以显式原子表示；CAP 令牌与原子互转。**禁止**自由字符串拼接状态。 |
| 状态机 | [`CapWorkbench.Cap.StateMachine`](lib/cap_workbench/cap/state_machine.ex) | 纯函数，按 `{state, event}` 显式模式匹配列出**所有**合法流转；无副作用、不碰数据库。 |
| CAP XML | [`CapWorkbench.Cap.Xml`](lib/cap_workbench/cap/xml.ex) | 用 Saxy 结构化 simple-form 构建 + `Saxy.encode!` 转义（**无字符串拼接**）；安全解析（拒绝 DOCTYPE、不展开外部实体）；命名空间感知、保留未知扩展字段做 round-trip。 |
| 服务 / 用例 | [`CapWorkbench.Alerts`](lib/cap_workbench/alerts.ex) | 唯一的状态变更入口：创建草稿、编辑（乐观锁）、提交复核、复核（拒绝过期结论）、发布（幂等 + 事务化 outbox/审计）、更正 / 解除。 |
| Schema | [`alert_message.ex`](lib/cap_workbench/cap/alert_message.ex) · [`draft_version.ex`](lib/cap_workbench/cap/draft_version.ex) · [`audit_event.ex`](lib/cap_workbench/cap/audit_event.ex) · [`outbox_entry.ex`](lib/cap_workbench/cap/outbox_entry.ex) | 消息聚合根 / 不可变版本快照 / 审计事件 / 通知 outbox。 |
| LiveView | [`MessageLive.Index`](lib/cap_workbench_web/live/message_live/index.ex) · [`MessageLive.Show`](lib/cap_workbench_web/live/message_live/show.ex) | 草稿编辑、版本差异、复核、发布 / 输出、审计 / 通知五个页签。 |
| HTTP API | [`Api.MessageController`](lib/cap_workbench_web/controllers/api/message_controller.ex) · [`Api.FallbackController`](lib/cap_workbench_web/controllers/api/fallback_controller.ex) | JSON API，冲突→409、校验失败→422。 |

### 关键一致性保证

- **不可变版本**：每次编辑都写入一条**全新** `draft_versions` 行，旧版本永不被修改。
- **乐观锁**：`alert_messages.lock_version` 保护聚合级流转；落后的写入者返回 `{:error, :stale}`，
  UI 提示并重载（两个浏览器改同一草稿不会互相覆盖）。
- **过期复核**：若在复核期间产生了更新草稿，旧的复核结论会被拒绝（`{:error, :stale_review}`）。
- **只发布通过复核的最新版本**，且**只发布一次**：发布 + 冻结版本 + 审计 + outbox 入队在**同一事务**内完成；
  任一环节失败整体回滚。重复 / 竞争发布由 outbox `dedupe_key` 唯一索引拦截（`{:error, :duplicate_publish}`）。
- **发布后冻结**：`save_new_version` 对已发布消息返回 `{:error, :not_editable}`；变更只能走更正 / 解除，
  发布更正 / 解除时其引用的前序消息在同一事务内被置为 `superseded`。
- **实时同步**：通过 `Phoenix.PubSub` 广播，任意会话的变更会即时刷新其他打开的工作台。

### CAP XML 安全

- 解析器（Saxy）**非验证型**，不解析 DTD、不获取外部实体。
- 额外拒绝任何含 `<!DOCTYPE>` 的文档（`{:error, :doctype_forbidden}`），从源头杜绝 XXE / 实体展开。
- 转义完全交由编码器完成，**round-trip 不会**把 `&amp;` 变成 `&amp;amp;`（见测试）。
- 未知 / 前向兼容的扩展字段（alert 级与 info 级）被保存在 `extensions` 中，导出时原样还原。

---

## 2. 环境要求

- Elixir ≥ 1.18 / OTP ≥ 27（本项目在 Elixir 1.20 / OTP 29 上开发）
- PostgreSQL（默认连接 `postgres/postgres@localhost`，见 [`config/dev.exs`](config/dev.exs)）
- Node 不是必需的——资产由 esbuild / tailwind 独立二进制处理

## 3. 快速开始

```bash
# 安装依赖、建库、迁移、灌入初始消息、构建资产
mix setup

# 启动服务（默认 4000 端口）
mix phx.server
# 若 4000 被占用，可指定端口：
PORT=4010 mix phx.server
```

打开 <http://localhost:4000/messages>（或你指定的端口）。根路径 `/` 会重定向到工作台列表。

## 4. 常用 Mix 命令

```bash
mix deps.get                      # 拉取依赖
mix ecto.create                   # 建库
mix ecto.migrate                  # 迁移
mix run priv/repo/seeds.exs       # 灌入初始消息（幂等）
mix ecto.reset                    # drop + create + migrate + seed
mix assets.build                  # 构建前端资产 (tailwind + esbuild)
mix assets.deploy                 # 生产资产（压缩 + digest）
mix format                        # 原生格式化
mix test                          # 运行测试（自动建测试库并迁移）
mix precommit                     # 编译(告警即错误) + 未用依赖检查 + 格式化 + 测试
```

## 5. 初始种子消息

[`priv/repo/seeds.exs`](priv/repo/seeds.exs) 幂等地创建标识 **`CN-20260729-GD-RAIN-001`** 的消息：

| 字段 | 值 |
|------|----|
| 发送时间 sent | `2026-07-29T08:00:00Z`（CAP 输出为 `+08:00` 即 `2026-07-29T16:00:00+08:00`） |
| 状态 status | `Actual` |
| 类型 msgType | `Alert` |
| 范围 scope | `Public` |
| 语言 language | `zh-CN` |
| 紧急度 urgency | `Immediate` |
| 严重度 severity | `Severe` |
| 确定性 certainty | `Likely` |
| 地区编码 geocode | `440800`、`440900` |

## 6. 工作流

```
起草 drafting ──save──▶ drafting
      │
      └─submit─▶ 复核中 in_review ──approve──▶ in_review ──publish──▶ 已发布 published
                        │                                                  │
                        └─reject──▶ drafting          更正/解除并发布 ──supersede──▶ 已被更正/解除 superseded
```

- **草稿编辑**：修改内容并「保存为新版本」（乐观锁保护）。
- **版本差异**：选择任意两个版本做字段级 diff。
- **复核**：对当前复核中的最新版本「通过」或「退回」。
- **发布 / 输出**：发布已通过复核的最新版本；预览 / 导出 CAP 1.2 XML。
- **审计 / 通知**：查看不可变审计事件流与通知 outbox（含 dedupe key）。

## 7. HTTP JSON API

所有变更端点需带 `lock_version`（乐观锁）；冲突返回 `409`，校验失败返回 `422`。

| 方法 & 路径 | 说明 |
|-------------|------|
| `GET /api/messages` | 列出消息 |
| `POST /api/messages` | 创建草稿（body: `{"message": {...}}`） |
| `GET /api/messages/:id` | 消息详情（含版本） |
| `POST /api/messages/:id/versions` | 保存新版本（body: `{"version": {...}, "lock_version": n}`） |
| `POST /api/messages/:id/submit` | 提交复核（`{"lock_version": n}`） |
| `POST /api/messages/:id/review` | 复核（`{"decision": "approve"\|"reject", "lock_version": n}`） |
| `POST /api/messages/:id/publish` | 发布（`{"lock_version": n}`） |
| `POST /api/messages/:id/correction` | 基于已发布消息创建更正 |
| `POST /api/messages/:id/cancellation` | 基于已发布消息创建解除 |
| `GET /api/messages/:id/export` | 导出 CAP 1.2 XML |
| `POST /api/messages/import` | 导入 CAP XML（`{"xml": "..."}`，安全解析） |

示例：导出并再导入（round-trip）

```bash
curl -s http://localhost:4010/api/messages > /tmp/list.json
ID=$(python3 -c "import json;print(json.load(open('/tmp/list.json'))['data'][0]['id'])")
curl -s "http://localhost:4010/api/messages/$ID/export"
```

## 8. 测试

```bash
mix test
```

覆盖：状态机全部合法 / 非法流转、乐观锁冲突、过期复核、重复发布、
**发布事务中途失败的整体回滚一致性**（页面状态 / 不可变版本 / 审计 / outbox）、
CAP XML round-trip（命名空间 / 特殊字符 / 未知扩展字段）、以及 XXE / DOCTYPE 防护。
