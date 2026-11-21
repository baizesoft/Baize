# 白泽编程语言（Baize）

- 项目定位：为中文原生设计的通用编程语言，P2 长期核心技术资产。客户交付（P0/P1）优先，不因本项目进度快而挤占交付资源。
- 分支约定：`main` 为稳定基线，`dev` 为研发分支。研发任务使用 `agent/<agent>/<task-id>` 独立分支，验收后再合入 `dev`。
- 源文件扩展名 `.bz`，源码 UTF-8。中文关键字、中文标识符、中文诊断、中文文档是语言核心，不是外围翻译层。
- 编译器源码在 `compiler/编译器.bz`。最终编译器必须由白泽自身实现，不依赖 Rust、Go、Python、C 等第三方高级语言；Stage 0 汇编种子与外部汇编器/链接器属于明确记录的过渡依赖，不得误称最终自主工具链。
- 自举验收以三代逐字节比对、可信根哈希、GNU/交叉独立对照为准。先定义契约和验收标准再编码；不以语法示例或愿景文案宣称完成。未实际复跑验收脚本时，"通过"只能算 B 档自述，交付时必须说明。

## 白泽团队协作

- Agent 接手入口见 [.agents/README.md](.agents/README.md)。
- `.baize/` 是白泽团队的多人协作目录。[knowledge](.baize/knowledge/README.md) 存放知识，[task](.baize/task/README.md) 存放任务，[memory](.baize/memory/README.md) 存放共享记忆。
- `.baize/` 由 Git 跟踪。更新后按本仓分支约定提交并推送，让协作者能从远端获取。凭据、原始客户资料和个人会话留在各自的授权存储中。


## 知识库配对

- 配对知识库：`E:\notes\baize_notes\BaizeLang\`，入口 `00-总索引.md`。接手前先读它，进度事实以 `01-进度存档.md` 为唯一真源。
- 重要架构决策、语言语义契约、阶段成果写入该知识库，并由空明独立审查。`E:\notes\仓颉` 是华为仓颉语言的学习笔记，与本项目无关。
- 工作日志与待验证问题留在知识库 `03-已知限制与治理欠账.md`，不在 README 里堆砌进度叙事。

## 工作区与产物

- `target/`、`build/`、`dist/`、`*.obj` 由 `.gitignore` 排除，属可重建产物。清理前先确认不是唯一证据。
- 根目录 `.bz` 若非 `compiler/编译器.bz`、`examples/` 或 `bootstrap/` 内的正式文件，视为临时测试程序。清理时先读内容、移到备份目录（如 `D:\tmp\baizelang-legacy-20261121\`），不要直接删除。
- `tests/` 用于可重复的语义回归用例（数据驱动，19 项，2026-11-21 本机全绿）；`scripts/` 是自举与端到端验收入口。两者职责不同，不要互相替代。新增用例只改 `tests/` 夹具与 manifest，不改 runner 逻辑。
- `docs/` 放语言契约与演示程序说明（`整数语义契约.md`、`计算器使用说明.md`）。整数边界（溢出回绕、零除与 INT_MIN÷-1 崩溃、除法向零截断）已在 `docs/整数语义契约.md` 基于实测定义，改动前先读。

## 文档结构（2026-11-21 拆分）

- `README.md` 只保留语言现状速查、自举入口、最小示例与导航（约 10 KB）。计算器完整功能说明在 `docs/计算器使用说明.md`，不要再把大段功能描述堆回 README。
- 两份生成器 `build/_gen_tests.py`、`build/_gen_runner.py`（被 gitignore）是 `tests/` 夹具与 runner 的唯一事实源；改用例优先改生成器再重新生成，保持 staging 与正式目录一致。
- 验收脚本（`scripts/check-stage0-trust-root.sh`、`check-native-windows.ps1` 等）改动后必须在对应平台复跑，并把结果回填知识库。

## 生态联动（2026-11-21 已定义接入约定）

- 白泽语言属于 P2 长期资产，**不挤占**白泽任务/通信的派单通道，但重大决策与验收结果必须留痕，不游离于生态闭环之外。
- **留痕通道**：BaizeBridge（`D:\code\BaizeBridge`，回环 HTTP `/send` `/receive` `/ack` `/receipt`）。消息信封字段用 `task_id` / `message_id` / `receiver` / `message_type` / `correlation_id`。
- **task_id 命名空间**：白泽语言任务一律用 `BAIZELANG-<序号>`（如 `BAIZELANG-0001`），与 `TASK-*`（白泽任务）、`TASK-BRIDGE-*`（通信）区分，避免看板投影串线。
- **消息类型映射**（对齐 Bridge 现有五种，不新造类型）：决策提出=`TASK_CREATED`、开始实现=`TASK_ACCEPTED`、阶段进展=`TASK_PROGRESS`、验收通过=`TASK_COMPLETED`、卡点/受阻=`TASK_BLOCKED`。`correlation_id` 串联同一决策的全生命周期。
- **验收口径**：Bridge 消息是"投递成功"的凭据，**不等于验收通过**——验收以本仓三代逐字节自举 / 可信根哈希 / `tests/` 回归结果为准（见上文档位规则），两者分离，遵守"进程退出≠验收"纪律。
- **登记处**：重大决策同时写配对知识库 `01-进度存档.md`（唯一事实源）与 `E:\notes\项目总索引.md`；是否投影到 BaizeTask 看板由统筹方（如意）决定，本项目只负责产出合规的 Bridge 消息与证据。
- 通用能力（证据记录、可信根校验、进度存档格式）若跨项目复用，按反向优化纪律回流到 gocomponents / pycomponents / rustcomponents，不在本项目内各写一遍。
