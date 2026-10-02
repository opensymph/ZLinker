# 对话页 · 官方 web 客户端功能对标（v1.10 后）

对标基准：`zai-org/ZCode` 仓库 `packages/ui/src/v4`（官方手机远控页 `/remote/v4` 配对成功后渲染的就是这套 UI；本 App 的 `lib/protocol/` 是同一条 relay/bridge 协议的 Dart 镜像）。官方源码本地克隆：`E:\ZRemote\ZCode`。

## 本轮已补齐（P0-P1）

| 功能 | 说明 | 主要代码 |
|---|---|---|
| 技能入口 | composer 工具条新增 ✨ 按钮（原实现已存在但从未接线） | `chat_page.dart` `_InputBarState` |
| 代码块语法高亮 | `highlight` 纯 Dart 包；VSCode Dark+ / GitHub Light 双主题；未知语言回退纯色 | `markdown_view.dart` |
| 计划批准卡 | ExitPlanMode 审批（userInput 通道 + plan_approval schema）；批准=`accept`+answer"approve"，带反馈拒绝=`accept`+反馈文本，纯拒绝=`decline` | `chat_page.dart` `_PlanApprovalCard` |
| Elicitation 表单 | 多题/多选/自定义回答/sensitive；提交格式对齐 `buildElicitationResponseContent`（answers/answer_N/answer） | `chat_page.dart` `_ElicitationForm` |
| Hook 审核卡 | `workspaceHookReview` kind；走专用 `respondWorkspaceHookReview` 命令（trust_selected） | `chat_page.dart` `_HookReviewCard`、`device_session.dart` |
| 结构化计划面板 | 当前 snapshot.plan 三态 + `plans()` RPC 历史计划（ExitPlanMode 行 → markdown） | `session_sheets.dart` `PlansSheet` |
| 结构化文件变更面板 | per-file ±计数 + readonly hunks diff + 撤销（复用 rewind 预检弹窗） | `session_sheets.dart` `FileChangesSheet` |
| statusPanel 扩展 | workflow 行（workflowRuns.runs × backgroundWorks kind=workflow，workId≡runId）+ 运行中 bash 行；原后台任务条升级 | `chat_page.dart` `_StatusPanel` |
| 会话内搜索 | userInput/assistantText 建索引、计数/上下条、无结果自动翻旧账（上限 1200 行，对齐 `FIND_AUTO_LOAD_ROW_LIMIT`） | `chat_page.dart` `_SearchBar` + `_reindexSearch` |
| 轮次跳转导航 | 右侧悬浮 rail（≥4 轮显示），点击跳转、可视区指示 | `chat_page.dart` `_TurnNavigatorRail` |
| 草稿持久化 | `chat.draft.<sessionId>`，离开保存、进入恢复 | `chat_page.dart` `_saveDraft`/`_restoreDraft` |
| 输入历史 | 最近 20 条，输入框为空时历史按钮 → bottom sheet 回填 | `chat_page.dart` `_openInputHistory` |
| Markdown 导出 | 前端拼装（远程图片降级为链接）；复制全文 / file_picker 存 .md（`share_plus` 无 ohos 实现，刻意不引入） | `chat_page.dart` `_buildExportMarkdown` |
| 工具卡补家族 | CronCreate/CronUpdate/OffPeakCreate（7 候选位解析）、workflow 族（含按名分流）、CUA 卡（display.kind=cua + 截图缩略图） | `chat_page.dart` `_toolSummary` |
| **工作流卡完整对齐（M1-M5）** | `WorkflowCard` 独立成 `workflow_card.dart`：横向轨道站台（宽 168/灯 10px/药丸 32px 官方几何）、站台状态灯（currentPhase/nodes 硬事实链）、参与者药丸（九色瓦片脸 + overlay 精确状态）、名册、march 光、心跳灯、扫光种类词、产物条、阶段化种类词、detail 串（阶段·子代理·工作中） | `workflow_card.dart` + `lib/protocol/workflow_runs.dart` |
| **Run 详情页** | 状态头（Resume/Stop 按钮门控 + 用量 + lineage）、纵向阶段轨道（运行站台自动展示参与者）、Artifacts 区（RPC 分块加载 + markdown/image/code 分派）、待回答问题区 | `workflow_run_page.dart` |
| **子代理 transcript 跳转** | 药丸点击 → 只读 ChatPage（sessionId 来自 run.actors，缺席 toast「尚未启动」） | `chat_page.dart` `readOnly` |
| **状态面板折叠分区** | 工作流/终端分区默认收起（官方 defaultOpen=false），收起态 = 标题 + 最长已运行 · N 个后台运行 | `chat_panels.dart` `StatusPanel` |
| 配额横幅 | `usage-stats` bridge 通道 `getEntitlementSnapshot`；model_usage 桶 remaining/number（percentage 兜底）→ 用尽/今日用尽/不足 10% | `chat_page.dart` `_QuotaBanner` |
| 空态推荐 prompt | 官方为云端 REST 下发（无凭证），本地静态 3 条兜底 | `chat_page.dart` `_DraftSuggestedPrompts` |

## 明确跳过（桌面形态 / 无数据源）

- **/side 副屏会话、分屏布局、集成终端面板、白板画板、内嵌浏览器、模型轨迹检查器** —— Electron/桌面交互形态，移动端无对应场景。
- **划词引用、ESC 停止、图片剪贴板粘贴** —— 键盘/鼠标语义；移动端选图走现有附件选择器。
- **@ 提及的 whiteboard/plugins 两类** —— 官方同样标注 desktop-only。
- **云端发布分享（/shares REST）、服务端下发推荐 prompt（client/scenes）** —— 需云端 OAuth 凭证，手机 pairing 链路没有；若将来拿到凭证可在 `_DraftSuggestedPrompts` 与导出处切换。
- **工作流卡仍为简化的部分**：站台轨道弧线/泳道分道几何、脸的眨眼与随机动作动画、药丸点击开子代理 transcript 在 actor 无 sessionId 时的占位 tab（现为 toast）。
- **statusPanel git 分区** —— 官方数据来自 workspace 级 `useGitRepository`，不在会话快照；`_StatusPanel._probeGit` 已留探测口（snapshot 出现 `git`/`gitSummary`/`gitRepository` 键即自动渲染），当前数据源未开放。
- **sources 引用折叠卡** —— 本仓库快照（3.14.3）无该工具卡协议来源。
- **CUA artifactUri 截图** —— 需要异步 `attachmentRead` 加载，当前无 gateway 通路，仅渲染内联 base64。

## 已知差异（有意为之）

- 队列重排用上下按钮而非拖拽（手机行宽不适合拖拽手柄，见 `_QueueBar` 注释）。
- 计划批准卡上「批准」不携带反馈框内容（反馈语义=拒绝理由，分属两个按钮）。
- 会话内搜索不做事中关键词高亮（官方 DOM 高亮是 web 专属实现），跳转定位为准。
