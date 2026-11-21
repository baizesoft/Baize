# 白泽语言语义回归测试（Windows 原生后端）

数据驱动的语义回归层，与 `scripts/` 的自举/端到端验收互补：`scripts/verify-seed.ps1` 验证信任链与编译器内部（词法/AST/发射），本目录验证**语言行为**（递归、循环、数组、文件 I/O、错误诊断等），并提供"新增用例不改脚本"的可扩展结构。

## 约定

- 仓库中受版本控制的 runner、manifest、夹具是复现依据；忽略目录内的本地生成器不能覆盖已审查的修订。
- 夹具 UTF-8 无 BOM，换行统一 `\n`；期望输出按**字节**比对，末尾换行算入。
- runner 是 PowerShell 5.1 脚本，**必须带 UTF-8 BOM**（无 BOM 会被 ANSI/GBK 解码导致中文与引号错乱）。
- 每轮从 `bootstrap/stage0/trust-root-windows/seed.pe` 构建一次可信编译器（走 `scripts/build-seed.ps1`），用同一编译器执行各用例；引导失败不评估用例。
- 所有临时产物写入 `build/_bztest_<stamp>/`（已被 `.gitignore` 的 `/build/` 覆盖），不逐文件删除。

## 运行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1
```

成功输出 `TOTAL=N PASS=N FAIL=0`，进程退出码 0；任一失败退出码 1。负向用例须返回 1、无产物，并在 stdout 命中 `expected_diagnostic` 指定的完整诊断行。

Linux 使用同一个 manifest：从可信根脚本的保留证据取得第三代编译器后，运行 `python3 -B tests/run-linux-tests.py <stage3>`。两个平台的布局验收另跑 `python3 -B tests/check-layout.py <第三代编译器路径>`。用于确认 Windows 引导故障不会产生假通过的对照是 `python3 -B tests/check-runner-fail-closed.py`。Python 只用于测试驱动，不参与自举或用户程序编译。

## 用例清单

| 用例 | 覆盖语义 |
| :--- | :--- |
| 01 问候与中文标识符 | UTF-8 中文字符串输出、中文标识符、整数输出 |
| 02 算术优先级 | 括号与四则运算优先级（`12 + 3 * (4 - 1) = 21`） |
| 03 变量赋值与表达式 | 整数变量重赋值、负数整除向零截断（`-7 / 3 = -2`） |
| 04 递归阶乘 | 函数、条件分支、递归调用 |
| 05 当循环累加 | `当` 循环、局部变量更新 |
| 06 零迭代求和 | 循环零迭代与多迭代、`返回` |
| 07 字节数组读写 | 全局字节数组存取值 |
| 08 负数恒等函数 | 负数参数与返回值、打印负路径无杂散字节 |
| 09 比较与布尔条件 | `>=`/`!=`/`==`、布尔比较结果输出、条件分支 |
| 10 命令行参数 | `参数数量()`/`参数读取()`、UTF-8 字节与首字符值 |
| 11 文件读写往返 | `文件读取`/`文件写入`、长度与内容往返 |
| E01-E03 负向用例 | 非法表达式、空程序、缺少语句分隔符——均须编译失败且不产 exe |

## 新增用例

1. 在 `cases/` 加 `<名字>.bz`；
2. 正向用例在 `expected/` 加同名 `.txt`（期望 stdout，**末尾要有换行**）；负向用例不建 expected，在 manifest 里标 `expect_fail: true` 和 `expected_diagnostic`；
3. 在 `manifest.json` 追加用例（需要参数时加 `"args":["..."]`）；
4. 重跑 runner，全绿即合入。

> [!note] 档位说明
> 本套例程 2026-11-21 已在本机 Windows x86-64 **实跑 14/14 通过**（详见 `E:\notes\baize_notes\BaizeLang\01-进度存档.md`）。它验证的是编译器行为，不等同于 `scripts/check-native-windows.ps1` 的三代逐字节自举验收——后者仍需单独复跑才能给"自举"结论升 A 档。
