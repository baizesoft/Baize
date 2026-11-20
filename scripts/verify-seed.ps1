$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$previousEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Push-Location $root
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build-seed.ps1') -Source 'examples\你好.bz' -Name verify_hello
    if ($LASTEXITCODE -ne 0) { throw '问候示例构建失败' }
    $hello = & (Join-Path $root 'build\verify_hello.exe') | Out-String
    if ($hello.Trim() -ne '你好，白泽！') { throw "问候输出不符：$hello" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build-seed.ps1') -Source 'examples\额外程序.bz' -Name verify_extra
    if ($LASTEXITCODE -ne 0) { throw '额外程序构建失败' }
    $extra = & (Join-Path $root 'build\verify_extra.exe') | Out-String
    if ($extra.Trim() -ne "120") { throw "额外程序输出不符：$extra" }
    $first = (Get-FileHash (Join-Path $root 'build\verify_extra.exe') -Algorithm SHA256).Hash
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build-seed.ps1') -Source 'examples\额外程序.bz' -Name verify_extra
    if ($LASTEXITCODE -ne 0) { throw '确定性复建失败' }
    $second = (Get-FileHash (Join-Path $root 'build\verify_extra.exe') -Algorithm SHA256).Hash
    if ($first -ne $second) { throw '生成 PE 不确定' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build-seed.ps1') -Source 'examples\字节数组.bz' -Name verify_bytes
    if ($LASTEXITCODE -ne 0) { throw '字节数组程序构建失败' }
    $bytes = & (Join-Path $root 'build\verify_bytes.exe') | Out-String
    if ($bytes.Trim() -ne '131') { throw "字节数组程序输出不符：$bytes" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build-seed.ps1') -Source 'examples\文件读写.bz' -Name verify_file_io
    if ($LASTEXITCODE -ne 0) { throw '文件读写程序构建失败' }
    $fileIo = & (Join-Path $root 'build\verify_file_io.exe') | Out-String
    if ($fileIo.Trim() -ne '135') { throw "文件读写结果不符：$fileIo" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build-seed.ps1') -Source 'examples\命令行参数.bz' -Name verify_args
    if ($LASTEXITCODE -ne 0) { throw '命令行参数程序构建失败' }
    $argResult = & (Join-Path $root 'build\verify_args.exe') 'Alpha' 'beta' | Out-String
    if ($argResult.Trim() -ne '72') { throw "命令行参数结果不符：$argResult" }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\build-seed.ps1') -Source 'compiler\编译器.bz' -Name verify_lexer
    if ($LASTEXITCODE -ne 0) { throw '白泽词法器构建失败' }
    $emitSource = '输出（“你好，白泽！”）' + "`n" + '输出（12 + 3 * (4 - 1)）'
    [IO.File]::WriteAllText((Join-Path $root 'build\emit_probe.bz'), $emitSource, [Text.UTF8Encoding]::new($false))
    $emitResult = & (Join-Path $root 'build\verify_lexer.exe') 'build\emit_probe.bz' 'build\emit_probe.exe' native-windows-x64 | Out-String
    if ($emitResult.Trim() -ne '1') { throw "白泽 PE 发射失败：$emitResult" }
    $emitHash1 = (Get-FileHash (Join-Path $root 'build\emit_probe.exe') -Algorithm SHA256).Hash
    & cmd.exe /d /c 'build\emit_probe.exe > build\emit_probe.out'
    if ($LASTEXITCODE -ne 0) { throw '白泽生成程序运行失败' }
    $emitOutput = [IO.File]::ReadAllText((Join-Path $root 'build\emit_probe.out'), [Text.UTF8Encoding]::new($false))
    if ($emitOutput -ne "你好，白泽！`n21`n") { throw "白泽生成程序输出错误：$emitOutput" }
    $emitVariables = '整数 总数 = 19' + "`n" + '总数 = 总数 + 2' + "`n" + '输出（总数）'
    [IO.File]::WriteAllText((Join-Path $root 'build\emit_variables.bz'), $emitVariables, [Text.UTF8Encoding]::new($false))
    $emitVariablesResult = & (Join-Path $root 'build\verify_lexer.exe') 'build\emit_variables.bz' 'build\emit_variables.exe' native-windows-x64 | Out-String
    if ($emitVariablesResult.Trim() -ne '1') { throw "白泽变量 AST 发射失败：$emitVariablesResult" }
    & cmd.exe /d /c 'build\emit_variables.exe > build\emit_variables.out'
    if ($LASTEXITCODE -ne 0) { throw '变量程序的生成物运行失败' }
    $variablesOutput = [IO.File]::ReadAllText((Join-Path $root 'build\emit_variables.out'), [Text.UTF8Encoding]::new($false))
    if ($variablesOutput -ne "21`n") { throw "变量赋值生成物输出错误：$variablesOutput" }
    $emitArraySource = '字节数组 缓冲[4]' + "`n" + '缓冲[0] = 65' + "`n" + '输出（缓冲[0]）'
    [IO.File]::WriteAllText((Join-Path $root 'build\emit_array.bz'), $emitArraySource, [Text.UTF8Encoding]::new($false))
    $emitArray = & (Join-Path $root 'build\verify_lexer.exe') 'build\emit_array.bz' 'build\emit_array.exe' native-windows-x64 | Out-String
    if ($emitArray.Trim() -ne '1') { throw "字节数组 PE 发射失败：$emitArray" }
    & cmd.exe /d /c 'build\emit_array.exe > build\emit_array.out'
    if ($LASTEXITCODE -ne 0) { throw '字节数组生成物运行失败' }
    $arrayOutput = [IO.File]::ReadAllText((Join-Path $root 'build\emit_array.out'), [Text.UTF8Encoding]::new($false))
    if ($arrayOutput -ne "65`n") { throw "数组存储/读取输出错误：$arrayOutput" }
    $emitFactorial = & (Join-Path $root 'build\verify_lexer.exe') 'examples\额外程序.bz' 'build\emit_factorial.exe' native-windows-x64 | Out-String
    if ($emitFactorial.Trim() -ne '1') { throw "递归函数 PE 发射失败：$emitFactorial" }
    & cmd.exe /d /c 'build\emit_factorial.exe > build\emit_factorial.out'
    if ($LASTEXITCODE -ne 0) { throw '递归函数生成物运行失败' }
    $factorialOutput = [IO.File]::ReadAllText((Join-Path $root 'build\emit_factorial.out'), [Text.UTF8Encoding]::new($false))
    if ($factorialOutput -ne "120`n") { throw "递归函数/条件分支输出错误：$factorialOutput" }
    $emitWhileSource = '整数 i = 1' + "`n" + '整数 total = 0' + "`n" + '当（i < 6） {' + "`n" + 'total = total + i' + "`n" + 'i = i + 1' + "`n" + '}' + "`n" + '输出（total）'
    [IO.File]::WriteAllText((Join-Path $root 'build\emit_while.bz'), $emitWhileSource, [Text.UTF8Encoding]::new($false))
    $emitWhile = & (Join-Path $root 'build\verify_lexer.exe') 'build\emit_while.bz' 'build\emit_while.exe' native-windows-x64 | Out-String
    if ($emitWhile.Trim() -ne '1') { throw "循环 PE 发射失败：$emitWhile" }
    & cmd.exe /d /c 'build\emit_while.exe > build\emit_while.out'
    if ($LASTEXITCODE -ne 0) { throw '循环生成物运行失败' }
    $whileOutput = [IO.File]::ReadAllText((Join-Path $root 'build\emit_while.out'), [Text.UTF8Encoding]::new($false))
    if ($whileOutput -ne "15`n") { throw "循环生成物输出错误：$whileOutput" }
    $emitResult2 = & (Join-Path $root 'build\verify_lexer.exe') 'build\emit_probe.bz' 'build\emit_probe.exe' native-windows-x64 | Out-String
    $emitHash2 = (Get-FileHash (Join-Path $root 'build\emit_probe.exe') -Algorithm SHA256).Hash
    if ($emitResult2.Trim() -ne '1' -or $emitHash1 -ne $emitHash2) { throw '白泽生成 PE 不确定' }
    [IO.File]::WriteAllText((Join-Path $root 'build\emit_changed.bz'), '输出（22）', [Text.UTF8Encoding]::new($false))
    $emitChanged = & (Join-Path $root 'build\verify_lexer.exe') 'build\emit_changed.bz' 'build\emit_changed.exe' native-windows-x64 | Out-String
    if ($emitChanged.Trim() -ne '1') { throw "不同输入的 PE 发射失败：$emitChanged" }
    & cmd.exe /d /c 'build\emit_changed.exe > build\emit_changed.out'
    if ($LASTEXITCODE -ne 0) { throw '不同输入的生成程序运行失败' }
    $changedOutput = [IO.File]::ReadAllText((Join-Path $root 'build\emit_changed.out'), [Text.UTF8Encoding]::new($false))
    if ($changedOutput -ne "22`n") { throw "输入变化没有改变程序行为：$changedOutput" }
    Set-Content (Join-Path $root 'build\lexer_sample.bz') 'alpha "hi" 17 +' -Encoding ascii
    $lexer = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_sample.bz') -join ','
    if ($lexer -ne '2,5,4,4,1,2,20,1') { throw "白泽词法器输出不符：$lexer" }
    $lexemeDump = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_sample.bz' '-dump') -join ','
    if ($lexemeDump -ne '2,5,97,108,112,104,97,4,4,34,104,105,34,1,2,49,55,20,1,43') { throw "token 词素切片不能还原：$lexemeDump" }
    Set-Content (Join-Path $root 'build\expr_good.bz') '12 + 3 * (4 - 1)' -NoNewline -Encoding ascii
    $exprGood = & (Join-Path $root 'build\verify_lexer.exe') 'build\expr_good.bz' x y | Out-String
    if ($exprGood.Trim() -ne '1') { throw "有效表达式解析失败：$exprGood" }
    $exprAst = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\expr_good.bz' x y z w) -join ','
    if ($exprAst -ne '7,6,0,5') { throw "AST 优先级结构错误：$exprAst" }
    $wideParts = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt 130; $i++) { if ($i -gt 0) { $wideParts.Add('+') }; $wideParts.Add('1') }
    [IO.File]::WriteAllText((Join-Path $root 'build\expr_ast_wide.bz'), ($wideParts -join ' '), [Text.UTF8Encoding]::new($false))
    $wideAst = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\expr_ast_wide.bz' x y z w) -join ','
    if ($wideAst -ne '259,6,256,257') { throw "AST 多字节节点引用错误：$wideAst" }
    Set-Content (Join-Path $root 'build\expr_call.bz') 'f(2)' -NoNewline -Encoding ascii
    $callAst = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\expr_call.bz' x y z w) -join ','
    if ($callAst -ne '4,7,3,0') { throw "函数调用 AST 节点错误：$callAst" }
    Set-Content (Join-Path $root 'build\ast_statements.bz') "整数 x = 1`n输出(x)" -NoNewline -Encoding utf8
    $statementAst = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\ast_statements.bz' a b c d e) -join ','
    if ($statementAst -ne '5,50,2,40') { throw "声明/输出语句 AST 错误：$statementAst" }
    Set-Content (Join-Path $root 'build\expr_bad.bz') '12 + * 3' -NoNewline -Encoding ascii
    $exprBad = & (Join-Path $root 'build\verify_lexer.exe') 'build\expr_bad.bz' x y | Out-String
    if ($exprBad.Trim() -ne '0') { throw "非法表达式未被拒绝：$exprBad" }
    Set-Content (Join-Path $root 'build\expr_unclosed.bz') '(12 + 3' -NoNewline -Encoding ascii
    $exprUnclosed = & (Join-Path $root 'build\verify_lexer.exe') 'build\expr_unclosed.bz' x y | Out-String
    if ($exprUnclosed.Trim() -ne '0') { throw "未闭合括号表达式未被拒绝：$exprUnclosed" }
    Set-Content (Join-Path $root 'build\expr_chain.bz') '1 < 2 < 3' -NoNewline -Encoding ascii
    $exprChain = & (Join-Path $root 'build\verify_lexer.exe') 'build\expr_chain.bz' x y | Out-String
    if ($exprChain.Trim() -ne '0') { throw "链式比较未被拒绝：$exprChain" }
    $trueLiteral = [string][char]0x771f
    [IO.File]::WriteAllText((Join-Path $root 'build\expr_true.bz'), $trueLiteral, [Text.UTF8Encoding]::new($false))
    $exprTrue = & (Join-Path $root 'build\verify_lexer.exe') 'build\expr_true.bz' x y | Out-String
    if ($exprTrue.Trim() -ne '1') { throw "真字面量解析失败：$exprTrue" }
    $falseLiteral = [string][char]0x5047
    [IO.File]::WriteAllText((Join-Path $root 'build\expr_false.bz'), $falseLiteral, [Text.UTF8Encoding]::new($false))
    $exprFalse = & (Join-Path $root 'build\verify_lexer.exe') 'build\expr_false.bz' x y | Out-String
    if ($exprFalse.Trim() -ne '1') { throw "假字面量解析失败：$exprFalse" }
    foreach ($sourceName in @('examples\你好.bz', 'examples\额外程序.bz', 'examples\字节数组.bz', 'examples\文件读写.bz', 'examples\命令行参数.bz', 'compiler\编译器.bz')) {
        $parseResult = & (Join-Path $root 'build\verify_lexer.exe') $sourceName x y z | Out-String
        if ($parseResult.Trim() -ne '1') { throw "白泽程序结构解析失败：$sourceName => $parseResult" }
    }
    Set-Content (Join-Path $root 'build\parse_bad.bz') '整数 x = 1 + * 2' -NoNewline -Encoding ascii
    $parseBad = & (Join-Path $root 'build\verify_lexer.exe') 'build\parse_bad.bz' x y z | Out-String
    if ($parseBad.Trim() -ne '0') { throw "非法程序结构未被拒绝：$parseBad" }
    Set-Content (Join-Path $root 'build\parse_empty.bz') '' -NoNewline -Encoding ascii
    $parseEmpty = & (Join-Path $root 'build\verify_lexer.exe') 'build\parse_empty.bz' x y z | Out-String
    if ($parseEmpty.Trim() -ne '0') { throw "空程序未被拒绝：$parseEmpty" }
    Set-Content (Join-Path $root 'build\parse_same_line.bz') '整数 x = 1 输出（2）' -NoNewline -Encoding utf8
    $parseSameLine = & (Join-Path $root 'build\verify_lexer.exe') 'build\parse_same_line.bz' x y z | Out-String
    if ($parseSameLine.Trim() -ne '0') { throw "缺少语句分隔符未被拒绝：$parseSameLine" }
    Set-Content (Join-Path $root 'build\lexer_bad_string.bz') '"oops' -NoNewline -Encoding ascii
    $badString = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_bad_string.bz') -join ','
    if ($badString -ne '5,5') { throw "未闭合字符串未产生错误 token：$badString" }
    Set-Content (Join-Path $root 'build\lexer_ops.bz') '== != <= >=' -NoNewline -Encoding ascii
    $operators = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_ops.bz') -join ','
    if ($operators -ne '6,2,6,2,6,2,6,2') { throw "双字符运算符未合并：$operators" }
    Set-Content (Join-Path $root 'build\lexer_punct.bz') '+ - * / = < > ( ) { } [ ] , ;' -NoNewline -Encoding ascii
    $punctuation = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_punct.bz') -join ','
    if ($punctuation -ne '20,1,21,1,22,1,23,1,24,1,25,1,26,1,27,1,28,1,29,1,30,1,31,1,32,1,33,1,34,1') { throw "单字符符号分类错误：$punctuation" }
    [IO.File]::WriteAllText((Join-Path $root 'build\lexer_fullwidth.bz'), '（alpha）；', [Text.UTF8Encoding]::new($false))
    $fullwidth = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_fullwidth.bz') -join ','
    if ($fullwidth -ne '27,3,2,5,28,3,34,3') { throw "全角标点分类或边界错误：$fullwidth" }
    $curlySample = [string]([char]0x7532) + [char]0x201c + [char]0x4f60 + [char]0x597d + [char]0x201d + [char]0x4e59
    [IO.File]::WriteAllText((Join-Path $root 'build\lexer_curly.bz'), $curlySample, [Text.UTF8Encoding]::new($false))
    $curlyTokens = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_curly.bz') -join ','
    if ($curlyTokens -ne '2,3,4,12,2,3') { throw "中文弯引号字符串边界错误：$curlyTokens" }
    $curlyEscape = [string][char]0x201c + 'a' + '\' + [char]0x201d + 'b' + [char]0x201d
    [IO.File]::WriteAllText((Join-Path $root 'build\lexer_curly_escape.bz'), $curlyEscape, [Text.UTF8Encoding]::new($false))
    $curlyEscaped = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_curly_escape.bz') -join ','
    if ($curlyEscaped -ne '4,12') { throw "转义中文弯引号边界错误：$curlyEscaped" }
    $curlyUnclosed = [string][char]0x201c + 'oops'
    [IO.File]::WriteAllText((Join-Path $root 'build\lexer_curly_bad.bz'), $curlyUnclosed, [Text.UTF8Encoding]::new($false))
    $curlyBad = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_curly_bad.bz') -join ','
    if ($curlyBad -ne '5,7') { throw "未闭合中文弯引号未报错：$curlyBad" }
    Set-Content (Join-Path $root 'build\lexer_escape.bz') '"a\"b" 2' -NoNewline -Encoding ascii
    $escapedString = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_escape.bz') -join ','
    if ($escapedString -ne '4,6,1,1') { throw "转义引号字符串边界错误：$escapedString" }
    [IO.File]::WriteAllText((Join-Path $root 'build\lexer_keyword.bz'), '如果 alpha', [Text.UTF8Encoding]::new($false))
    $keywords = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_keyword.bz') -join ','
    if ($keywords -ne '7,6,2,5') { throw "关键字与标识符区分错误：$keywords" }
    [IO.File]::WriteAllText((Join-Path $root 'build\lexer_keywords.bz'), '函数 返回 当 否则 整数 布尔 字节数组 输出 如果 普通标识符', [Text.UTF8Encoding]::new($false))
    $keywordSet = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_keywords.bz') -join ','
    if ($keywordSet -ne '8,6,9,6,10,3,11,6,12,6,13,6,14,12,15,6,7,6,2,15') { throw "保留字分类结果错误：$keywordSet" }
    Set-Content (Join-Path $root 'build\lexer_comment.bz') "alpha # ignored`n17" -NoNewline -Encoding ascii
    $commentTokens = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_comment.bz') -join ','
    if ($commentTokens -ne '2,5,1,2') { throw "行注释内容被误识别为 token：$commentTokens" }
    [IO.File]::WriteAllText((Join-Path $root 'build\lexer_bom.bz'), '如果 alpha', [Text.UTF8Encoding]::new($true))
    $bomTokens = @(& (Join-Path $root 'build\verify_lexer.exe') 'build\lexer_bom.bz') -join ','
    if ($bomTokens -ne '7,6,2,5') { throw "UTF-8 BOM 未跳过：$bomTokens" }
    Write-Output "种子检查通过；额外程序 PE SHA-256：$second"
} finally { Pop-Location; [Console]::OutputEncoding = $previousEncoding }
