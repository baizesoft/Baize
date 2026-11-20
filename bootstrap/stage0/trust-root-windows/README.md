# Windows x86-64 可信种子

seed.pe 是白泽编译器生成的 PE32+ 编译器。从当前仓库的 Linux x86-64 可信种子冷启动，验证 Linux 三代固定点后，使用第三代白泽编译器把 compiler/编译器.bz 编译为 native-windows-x64。种子的 SHA-256 记录在同目录的 SEED-SHA256SUMS。

在仓库根目录运行 powershell -NoProfile -File scripts/check-native-windows.ps1。从 Windows 可信种子冷启动，验证种子哈希并连续编译三代。脚本逐字节比较三代产物，再用第三代编译器编译带中文和空格路径的样例，并运行样例核对退出码。

CI 同时从 Linux 可信根构建当前源码对应的 Windows 编译器，再与 Windows 直接自举的第三代比较。种子固定为移除旧后端后的首次验收版本。源码更新后，三代产物仍应彼此一致，并与 Linux 交叉编译产物一致。复现本次种子时，使用引入该种子的源码版本，设置 BAIZE_BOOTSTRAP_ARTIFACTS 运行 Linux 可信冷启动，再用其中 native 目录下的 stage3 交叉编译。

Windows 冷启动使用系统自带的 64 位 PowerShell，编译器及产物只依赖 Windows 系统 API。冷启动不需要安装 WSL、Rust、C 编译器、汇编器或链接器。
