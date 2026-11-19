# 白泽 0.1（编译器自举原型）

白泽源码使用 UTF-8 和 `.bz` 后缀。冷启动编译器由 Rust 实现；自举编译器 `compiler/编译器.bz` 用白泽实现词法扫描、递归下降语法分析、AST 构造和 C 代码发射。Rust 种子可编译该源码生成 stage1；stage1、stage2、stage3 已能连续编译同一编译器源码，且 stage1/2/3 对该源码生成的 C 字节一致。Rust 种子只负责生成 stage1；自举验证随后会禁用其可执行文件，再由 stage1 生成 stage2、stage2 生成 stage3。冷启动仍需 Rust。

## 当前语言范围

源语言支持中文关键字和标识符、UTF-8 字符串（ASCII 双引号与中文弯引号）、数字/布尔字面量、一元负号、算术与比较表达式、函数/参数/递归调用、整型变量、固定大小字节数组及索引读写、赋值、条件/否则、循环、返回和输出。C 发射器支持这些结构的当前子集；编译器自身的大型词法/解析/发射程序可由自举链编译。编译器源中插入普通函数可改变生成 C，且编辑后 C 通过 MSVC 构建。

语句由换行或全角分号分隔；括号可使用全角或 ASCII 形式，函数体使用 ASCII 花括号。生成 C 的运行时只提供通用输出、文件 I/O 和命令行 API 包装，不包含白泽编译逻辑。数组定长，当前不做边界检查。Windows 非 ASCII 文件路径和命令行参数编码尚未验证。

## Windows 构建和验证

依赖 Rust/Cargo、Visual Studio 2022 MSVC 和 Windows SDK。脚本通过 `vcvars64.bat` 初始化 `cl.exe`：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-seed.ps1
.\build\demo.exe
powershell -ExecutionPolicy Bypass -File scripts/verify-seed.ps1
powershell -ExecutionPolicy Bypass -File scripts/verify-bootstrap.ps1
```

`verify-seed.ps1` 运行种子单测和示例。`verify-bootstrap.ps1` 构建 Rust seed 和 stage1，把 seed 可执行文件移出原路径后，在独立目录生成/构建 stage2、stage3，并比对三代对编译器源码生成的 C SHA-256；还会用 stage1/stage2 编译运行中文问候、BOM 与长中文注释偏移样例、转义字符串输出、262144 字节容量上限及超限拒绝、一元负数、括号嵌套及负数除法/运算优先级、局部数组参数与返回值、真假布尔条件、阶乘、新生成的阶乘 6 输入和文件读写往返（校验文件字节）、命令行参数读取，检查非法语法中文诊断，并逐例比对 stage1/stage2 生成 C 的哈希；修改编译器 `.bz` 源也会改变 C 输出，编辑版仍可由 MSVC 编译。

## 当前缺口

**Windows/MSVC 上的编译器自举链已验证。** 冷启动仍需 Rust seed，后续各代无需 Rust，但仍依赖 C 工具链。语法负例会报告中文错误、源码行号和 UTF-8 字节偏移；当前错误类别仍较通用，未输出具体期待的 token，拒绝时的进程退出码也不一定非零。源文件最大读取容量为 262144 字节，容量边界和超限拒绝均由 stage1/stage2 验证。
