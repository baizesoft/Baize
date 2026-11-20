param([switch]$Verify, [string]$WorkerPath)

$ErrorActionPreference = 'Stop'
if ($WorkerPath) {
    $worker = Get-Item -LiteralPath $WorkerPath
    if ($worker.PSIsContainer) { throw "白泽运算程序必须是文件：$WorkerPath" }
    $workerPath = $worker.FullName
} else {
    $root = Split-Path -Parent $PSScriptRoot
    $buildScript = Join-Path $PSScriptRoot 'build-seed.ps1'
    $compilerPath = Join-Path $root 'build/calculator-dev-compiler.exe'
    $workerPath = Join-Path $root 'build/baize-calculator-dev.exe'
    $compilerInputs = @($buildScript, (Join-Path $root 'compiler/编译器.bz'),
        (Join-Path $root 'bootstrap/stage0/trust-root-windows/seed.pe'),
        (Join-Path $root 'bootstrap/stage0/trust-root-windows/SEED-SHA256SUMS'))
    $compiler = Get-Item -LiteralPath $compilerPath -ErrorAction SilentlyContinue
    $newestInput = (Get-Item -LiteralPath $compilerInputs | Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1).LastWriteTimeUtc
    if (!$compiler -or $compiler.LastWriteTimeUtc -lt $newestInput) {
        & $buildScript -Source 'compiler\编译器.bz' -Name 'calculator-dev-compiler'
        $compiler = Get-Item -LiteralPath $compilerPath
    }
    $source = Get-Item -LiteralPath (Join-Path $root 'examples/计算器.bz')
    $worker = Get-Item -LiteralPath $workerPath -ErrorAction SilentlyContinue
    if (!$worker -or $worker.LastWriteTimeUtc -lt $source.LastWriteTimeUtc -or
        $worker.LastWriteTimeUtc -lt $compiler.LastWriteTimeUtc) {
        & $buildScript -Source 'examples\计算器.bz' -Name 'baize-calculator-dev' -CompilerPath $compilerPath
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$session = @{ Process = $null }
$invariant = [Globalization.CultureInfo]::InvariantCulture

function Start-BaizeSession {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $workerPath
    $start.Arguments = '--serve'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $session.Process = [Diagnostics.Process]::Start($start)
    $session.EditDisplay = $false
    if ($memorySlot.SelectedIndex -gt 0) {
        [void](Invoke-BaizeKey ([string][char](106 + $memorySlot.SelectedIndex)))
    }
}

function Stop-BaizeSession {
    $process = $session.Process
    if ($null -eq $process) { return }
    $session.Process = $null
    try {
        if (!$process.HasExited) {
            try { $process.StandardInput.Close() } catch [IO.IOException] {}
            if (!$process.WaitForExit(1000)) {
                try { $process.Kill() } catch [InvalidOperationException] {}
                [void]$process.WaitForExit(1000)
            }
        }
    } finally {
        $process.Dispose()
    }
}

function Read-BaizeFrameLine($Reader, [Diagnostics.Stopwatch]$Clock, [int]$TimeoutMs = 2000) {
    $remaining = $TimeoutMs - $Clock.ElapsedMilliseconds
    if ($remaining -le 0) { throw '白泽计算进程未返回完整结果' }
    $read = $Reader.ReadLineAsync()
    if (!$read.Wait([int]$remaining) -or $null -eq $read.Result) {
        throw '白泽计算进程未返回完整结果'
    }
    return $read.Result
}

class CalculationHistoryEntry {
    [string] $Expression
    [string] $Result
    [long] $InternalValue

    CalculationHistoryEntry([string]$expression, [string]$result, [long]$internalValue) {
        $this.Expression = $expression
        $this.Result = $result
        $this.InternalValue = $internalValue
    }

    [string] ToString() {
        return "$($this.Expression) = $($this.Result)"
    }
}

if ($Verify) {
    $historyPath = Join-Path ([IO.Path]::GetTempPath()) ('BaizeCalculator-' + [Guid]::NewGuid() + '.json')
} else {
    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $historyPath = Join-Path $localData 'BaizeCalculator\history.json'
}
$historyMutexName = 'Local\BaizeCalculator.History.' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($Verify) { $historyMutexName += '.' + [Guid]::NewGuid() }

function Read-CalculatorHistory {
    if (![IO.File]::Exists($historyPath)) { return }
    try {
        if ([IO.FileInfo]::new($historyPath).Length -gt 131072) { return }
        $rows = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($historyPath))
        foreach ($row in ($rows | Select-Object -First 50)) {
            $value = 0L
            if ($row.Expression -is [string] -and $row.Result -is [string] -and
                $row.Expression.Length -le 1024 -and $row.Result.Length -le 32 -and
                [long]::TryParse([string]$row.InternalValue, [Globalization.NumberStyles]::Integer, $invariant, [ref]$value) -and
                $value -ge -2147483647000000000 -and $value -le 2147483647000000000) {
                [CalculationHistoryEntry]::new($row.Expression, $row.Result, $value)
            }
        }
    } catch {
        Write-Warning '无法读取计算历史。'
    }
}

$pendingHistory = [Collections.Generic.List[CalculationHistoryEntry]]::new()

function Save-CalculatorHistory([CalculationHistoryEntry]$Entry) {
    if ($null -ne $Entry) {
        $pendingHistory.Insert(0, $Entry)
        if ($pendingHistory.Count -gt 50) { $pendingHistory.RemoveAt(50) }
    }
    $mutex = [Threading.Mutex]::new($false, $historyMutexName)
    $locked = $false
    $temporaryPath = $null
    try {
        try { $locked = $mutex.WaitOne(500) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (!$locked) { throw '等待历史文件写入超时' }
        if ($null -eq $Entry) {
            [IO.File]::Delete($historyPath)
            $pendingHistory.Clear()
            return $true
        }
        $rows = $pendingHistory.ToArray()
        if ($rows.Length -lt 50) {
            $rows += @(Read-CalculatorHistory | Select-Object -First (50 - $rows.Length))
        }
        $records = @(
            foreach ($row in $rows) {
                @{
                    Expression = $row.Expression
                    Result = $row.Result
                    InternalValue = $row.InternalValue.ToString($invariant)
                }
            }
        )
        $directory = [IO.Path]::GetDirectoryName($historyPath)
        [void][IO.Directory]::CreateDirectory($directory)
        $temporaryPath = Join-Path $directory ([Guid]::NewGuid().ToString() + '.tmp')
        [IO.File]::WriteAllText($temporaryPath, (ConvertTo-Json -InputObject $records -Compress), [Text.Encoding]::UTF8)
        if ([IO.File]::Exists($historyPath)) {
            [IO.File]::Replace($temporaryPath, $historyPath, [NullString]::Value)
        } else {
            [IO.File]::Move($temporaryPath, $historyPath)
        }
        $pendingHistory.Clear()
        return $true
    } catch {
        return $false
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        if ($temporaryPath -and [IO.File]::Exists($temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -ErrorAction SilentlyContinue
        }
    }
}

function Format-BaizeValue([long]$Scaled) {
    return (([decimal]$Scaled / 100000000).ToString('0.########', $invariant))
}

function Format-BaizeInternalValue([long]$Scaled) {
    return ([decimal]$Scaled / 1000000000).ToString('0.#########', $invariant)
}

function Format-StandardDisplay([string]$Value) {
    $parts = $Value.Split('.', 2)
    $parts[0] = [regex]::Replace($parts[0], '(?<=[0-9])(?=(?:[0-9]{3})+\z)', ',')
    return $parts -join '.'
}

function Send-BaizeCommand([string]$Key) {
    $process = $session.Process
    if ($null -eq $process -or $process.HasExited) { throw '白泽计算进程已经停止' }
    $writer = $process.StandardInput.BaseStream
    $bytes = [Text.Encoding]::ASCII.GetBytes($Key)
    $writer.Write($bytes, 0, $bytes.Length)
    $writer.Flush()
}

function Invoke-BaizeKey([string]$Key) {
    $command = $Key
    if (!$session.EditDisplay) {
        $command = 'J' + $command
        $session.EditDisplay = $true
    }
    Send-BaizeCommand $command
    $reader = $session.Process.StandardOutput
    $frameClock = [Diagnostics.Stopwatch]::StartNew()
    $code = [int]::Parse((Read-BaizeFrameLine $reader $frameClock), $invariant)
    $inputWarning = switch ($code) {
        8 { '输入超出计算器范围' }
        9 { '最多输入八位小数' }
    }
    if ($inputWarning) { $code = 0 }
    $scaled = [long]::Parse((Read-BaizeFrameLine $reader $frameClock), $invariant)
    $operation = [int]::Parse((Read-BaizeFrameLine $reader $frameClock), $invariant)
    [void](Read-BaizeFrameLine $reader $frameClock)
    [void](Read-BaizeFrameLine $reader $frameClock)
    $internalValue = [long]::Parse((Read-BaizeFrameLine $reader $frameClock), $invariant)
    $places = [int]::Parse((Read-BaizeFrameLine $reader $frameClock), $invariant)
    $pending = [int]::Parse((Read-BaizeFrameLine $reader $frameClock), $invariant)
    $accumulator = [long]::Parse((Read-BaizeFrameLine $reader $frameClock), $invariant)
    $errorOffset = if ($Key[0] -in @('T', 'U')) { [int]::Parse((Read-BaizeFrameLine $reader $frameClock), $invariant) } else { -1 }
    $expression = ''
    $entry = $null
    $output = switch ($code) {
        0 {
            if ($scaled -eq 0 -and $internalValue -ne 0) {
                ([decimal]$internalValue / 1000000000).ToString('0.#########', $invariant)
            } else {
                Format-BaizeValue $scaled
            }
        }
        1 { '计算错误：无效按键' }
        2 { '计算错误：不能除以零' }
        3 { '计算错误：整数超出计算器范围' }
        4 { '计算错误：表达式嵌套过深' }
        5 { '计算错误：算式小数最多九位' }
        6 { '计算错误：负数不能开平方根' }
        7 { '计算错误：当前没有可用于 ans 的数值' }
        default { throw "未知运算状态：$code" }
    }
    if ($operation -ne 0) {
        $left = [long]::Parse((Read-BaizeFrameLine $reader $frameClock), $invariant)
        $right = [long]::Parse((Read-BaizeFrameLine $reader $frameClock), $invariant)
    }
    if ($code -eq 0 -and $operation -ne 0) {
        $leftText = Format-StandardDisplay (([decimal]$left / 1000000000).ToString('0.#########', $invariant))
        $rightText = Format-StandardDisplay (([decimal]$right / 1000000000).ToString('0.#########', $invariant))
        $expression = switch ($operation) {
            43 { "$leftText + $rightText" }
            45 { "$leftText − $rightText" }
            42 { "$leftText × $rightText" }
            47 { "$leftText ÷ $rightText" }
            { $_ -gt 200 -and $_ -lt 300 } { "$leftText ÷ $rightText" + ('%' * ($operation - 200)) }
            { $_ -gt 300 } { "$leftText × $rightText" + ('%' * ($operation - 300)) }
            81 { "√($leftText)" }
            83 { "($leftText)²" }
            82 { "1 ÷ $leftText" }
            default { throw "未知历史运算：$operation" }
        }
        $entry = [CalculationHistoryEntry]::new($expression, (Format-StandardDisplay $output), $internalValue)
    } elseif ($code -eq 0 -and $Key.StartsWith('T', [StringComparison]::Ordinal)) {
        $expression = $Key.Substring(1).TrimEnd().Replace('*', '×').Replace('/', '÷')
        $entry = [CalculationHistoryEntry]::new($expression, (Format-StandardDisplay $output), $internalValue)
    }
    if ($pending -ne 0) {
        $symbol = switch ($pending) {
            43 { '+' }
            45 { '−' }
            42 { '×' }
            47 { '÷' }
            default { throw "未知待完成运算：$pending" }
        }
        $expression = "$(Format-StandardDisplay (([decimal]$accumulator / 1000000000).ToString('0.#########', $invariant))) $symbol"
    } elseif ($null -ne $entry -and ($operation -lt 48 -or $operation -gt 200)) {
        $expression += ' ='
    }
    if ($code -eq 0) {
        if ($places -eq -11) {
            $output = '-0'
        } elseif ($places -ne -1) {
            $negativeZero = $places -lt -1
            if ($negativeZero) { $places = -2 - $places }
            $value = [decimal]$scaled / 100000000
            $output = $value.ToString("F$places", $invariant)
            if ($places -eq 0) { $output += '.' }
            if ($negativeZero) { $output = '-' + $output }
        }
    }
    if ($code -eq 0) { $output = Format-StandardDisplay $output }
    if ($inputWarning) { $expression = $inputWarning }
    return @{ Code = $code; Output = $output; Expression = $expression; ErrorOffset = $errorOffset; HistoryEntry = $entry; InternalValue = $internalValue }
}

$form = [Windows.Forms.Form]::new()
$form.Text = '白泽计算器'
$form.ClientSize = [Drawing.Size]::new(364, 782)
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.KeyPreview = $true
$form.BackColor = [Drawing.ColorTranslator]::FromHtml('#192128')
$form.ForeColor = [Drawing.ColorTranslator]::FromHtml('#FAF4E7')
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 12)

$expressionLabel = [Windows.Forms.Label]::new()
$expressionLabel.SetBounds(182, 14, 166, 30)
$expressionLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$expressionLabel.ForeColor = [Drawing.ColorTranslator]::FromHtml('#B4C3C4')
$expressionLabel.AutoEllipsis = $true
$form.Controls.Add($expressionLabel)

$resultLabel = [Windows.Forms.Label]::new()
$resultLabel.SetBounds(16, 44, 332, 92)
$resultLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$resultLabel.Font = [Drawing.Font]::new('Microsoft YaHei UI', 23)
$resultLabel.Text = '0'
$form.Controls.Add($resultLabel)

$state = @{ CanCopy = $true; InternalValue = 0L; HistoryVisible = $false; Compact = $false }
$copyToClipboard = { param([string]$Value) [Windows.Forms.Clipboard]::SetText($Value) }
$readClipboard = { [Windows.Forms.Clipboard]::GetText() }
if ($Verify) {
    $copyState = @{ Text = $null; Input = $null }
    $readClipboard = { $copyState.Input }
    $copyToClipboard = { param([string]$Value) $copyState.Text = $Value }
}

$historyList = [Windows.Forms.ListBox]::new()
$historyList.SetBounds(380, 63, 296, 488)
$historyList.BackColor = [Drawing.ColorTranslator]::FromHtml('#243138')
$historyList.ForeColor = $form.ForeColor
$historyList.HorizontalScrollbar = $true
$historyList.Visible = $false
$form.Controls.Add($historyList)
foreach ($entry in (Read-CalculatorHistory)) { [void]$historyList.Items.Add($entry) }

function Copy-CalculatorResult([switch]$FullPrecision) {
    if (!$state.CanCopy) { return }
    try {
        $value = $resultLabel.Text
        if ($FullPrecision) {
            $value = Format-BaizeInternalValue $state.InternalValue
        }
        & $copyToClipboard $value
    } catch [Runtime.InteropServices.ExternalException] {
        $expressionLabel.Text = '剪贴板正忙，请重试'
    }
}

function Submit-CalculatorExpression([string]$Value, [ref]$ErrorIndex, [ref]$PreviewValue) {
    $value = $Value.Trim().Replace('−', '-')
    $value = $value.Replace('×', '*').Replace('÷', '/').Replace('√', 'sqrt').Replace('²', '^2').Replace('π', 'pi')
    if ($value.Length -le 2048 -and $value.Contains(',')) {
        $value = [regex]::Replace($value, '(?<![0-9.,])[0-9]{1,3}(?:,[0-9]{3})+(?![0-9,])', {
            param($match)
            $match.Value.Replace(',', '')
        })
    }
    if ($value -notmatch '\A[0-9a-zE+*/^%(). \t-]{1,1024}\z') {
        return '请输入有效算式，支持四则运算、括号、乘方和函数。'
    }
    $commandKey = if ($null -eq $PreviewValue) { 'T' } else { 'U' }
    $result = Apply-CalculatorCommand ("{0}{1}{2}" -f $commandKey, $value, [char]10) -PassThru
    if ($null -eq $result) { return $resultLabel.Text }
    if ($result.Code -ne 0) {
        if ($result.Code -eq 1 -and $null -ne $ErrorIndex) {
            # Map ASCII parser offsets back to the original editor text.
            $source = $Value.Trim()
            $leading = $Value.Length - $Value.TrimStart().Length
            $remaining = $result.ErrorOffset
            for ($i = 0; $i -lt $source.Length; $i++) {
                $width = switch ([string]$source[$i]) {
                    '√' { 4 }
                    { $_ -in @('π', '²') } { 2 }
                    ',' { 0 }
                    default { 1 }
                }
                if ($remaining -lt $width) { break }
                $remaining -= $width
            }
            $ErrorIndex.Value = $leading + $i
        }
        if ($result.Code -eq 1) { return '计算错误：无效算式' }
        return $result.Output
    }
    if ($null -ne $PreviewValue) { $PreviewValue.Value = $result.Output }
}

function Paste-CalculatorValue([switch]$Expression) {
    try {
        $value = ([string](& $readClipboard)).Trim().Replace('−', '-')
    } catch [Runtime.InteropServices.ExternalException] {
        $expressionLabel.Text = '剪贴板正忙，请重试'
        return
    }
    if ($Expression) {
        $message = Submit-CalculatorExpression $value
        if ($message) { $expressionLabel.Text = $message }
        return
    } elseif ($value -notmatch '\A[0-9.,eE+-]{1,32}\z') {
        $expressionLabel.Text = '请粘贴单个有效数字'
        return
    }
    Apply-CalculatorCommand ("P{0}{1}" -f $value, [char]10)
}

function Restore-CalculatorHistory {
    $entry = $historyList.SelectedItem
    if ($null -eq $entry -or $null -eq $session.Process) { return }
    $command = "I$($entry.InternalValue.ToString($invariant))`n"
    Apply-CalculatorCommand $command
}
$historyList.Add_DoubleClick({ Restore-CalculatorHistory })
$historyList.AccessibleName = '计算历史'
$historyList.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    if ([int]$eventArgs.KeyCode -eq 13) { $eventArgs.IsInputKey = $true }
})
$historyList.Add_KeyDown({
    param($sender, $eventArgs)
    if ([int]$eventArgs.KeyCode -eq 13) {
        Restore-CalculatorHistory
        $eventArgs.SuppressKeyPress = $true
    }
})

function New-CalculatorActionButton([string]$Text, [int]$Left, [int]$Top, [int]$Width) {
    $button = [Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.SetBounds($Left, $Top, $Width, 37)
    $button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = [Drawing.ColorTranslator]::FromHtml('#2B3940')
    $form.Controls.Add($button)
    return $button
}

$pinButton = [Windows.Forms.CheckBox]::new()
$pinButton.Appearance = 'Button'
$pinButton.Text = '置顶'
$pinButton.TextAlign = 'MiddleCenter'
$pinButton.AccessibleName = '窗口置顶'
$pinButton.AccessibleDescription = '快捷键 Ctrl+T'
$pinButton.SetBounds(16, 14, 78, 30)
$pinButton.FlatStyle = 'Flat'
$pinButton.FlatAppearance.BorderSize = 0
$pinButton.FlatAppearance.CheckedBackColor = [Drawing.ColorTranslator]::FromHtml('#F1C56C')
$pinButton.BackColor = [Drawing.ColorTranslator]::FromHtml('#2B3940')
$pinButton.Add_CheckedChanged({
    param($sender, $eventArgs)
    $form.TopMost = $sender.Checked
    if ($sender.Checked) {
        $sender.Text = '取消置顶'
        $sender.ForeColor = $form.BackColor
    } else {
        $sender.Text = '置顶'
        $sender.ForeColor = $form.ForeColor
    }
})
$form.Controls.Add($pinButton)

$copyButton = New-CalculatorActionButton '复制结果' 16 565 162
$copyButton.Add_Click({ Copy-CalculatorResult })
$historyButton = New-CalculatorActionButton '查看历史' 184 565 162
$historyClear = New-CalculatorActionButton '清空历史' 380 609 144
$historyRestore = New-CalculatorActionButton '使用结果' 380 565 144
$historyCopy = New-CalculatorActionButton '复制算式' 532 609 144
$historyEdit = New-CalculatorActionButton '编辑算式' 532 565 144
$historyClear.Visible = $false
$historyRestore.Visible = $false
$historyCopy.Visible = $false
$historyCopy.Enabled = $false
$historyEdit.Visible = $false
$historyEdit.Enabled = $false
$historyList.Add_SelectedIndexChanged({
    $selected = $null -ne $historyList.SelectedItem
    $historyCopy.Enabled = $selected
    $historyEdit.Enabled = $selected
})
$historyEdit.Add_Click({
    $entry = $historyList.SelectedItem
    if ($null -ne $entry) { Open-CalculatorExpressionDialog $entry.Expression }
})
$historyCopy.Add_Click({
    $entry = $historyList.SelectedItem
    if ($null -eq $entry) { return }
    try { & $copyToClipboard $entry.Expression }
    catch [Runtime.InteropServices.ExternalException] { $expressionLabel.Text = '剪贴板正忙，请重试' }
})
$historyClear.Add_Click({
    if (!(Save-CalculatorHistory $null)) {
        $expressionLabel.Text = '无法清空计算历史，请重试'
        return
    }
    $historyList.Items.Clear()
    if ($expressionLabel.Text -eq '无法清空计算历史，请重试') {
        $expressionLabel.Text = ''
    }
})
$historyRestore.Add_Click({ Restore-CalculatorHistory })
function Update-CalculatorHistoryLayout {
    $showHistory = $state.HistoryVisible -and !$state.Compact
    foreach ($control in @($historyList, $historyClear, $historyRestore, $historyCopy, $historyEdit)) { $control.Visible = $showHistory }
    if ($state.Compact) { return }
    if ($showHistory) {
        $form.ClientSize = [Drawing.Size]::new(692, 782)
        $historyButton.Text = '收起历史'
    } else {
        $form.ClientSize = [Drawing.Size]::new(364, 782)
        $historyButton.Text = '查看历史'
    }
}
$historyButton.Add_Click({
    $state.HistoryVisible = !$state.HistoryVisible
    Update-CalculatorHistoryLayout
})
$buttons = @{}
$memoryKeys = @('MC', 'MR', 'M+', 'M−', 'MS')
$keys = $memoryKeys + @(
    '%', 'CE', '清除', '退格',
    '1/x', 'x²', '√', '÷',
    '7', '8', '9', '×',
    '4', '5', '6', '−',
    '1', '2', '3', '+',
    '±', '0', '.', '='
)

$programmerWidths = [ordered]@{ BYTE = 8; WORD = 16; DWORD = 32; QWORD = 64 }
$programmerOperations = [ordered]@{
    '进制转换' = 'v'; 'AND' = 'a'; 'OR' = 'o'; 'XOR' = 'x'
    'NOT' = 'n'; '左移' = 'l'; '逻辑右移' = 'r'; '算术右移' = 'h'
    '循环左移' = 'L'; '循环右移' = 'R'; '字节序反转' = 'b'
    '位序反转' = 'B'; '差异位计数' = 'q'; '提取位字段' = 'f'; '提取有符号位字段' = 'F'; '写入位字段' = 'i'
    '置位计数' = 'p'; '前导零计数' = 'c'; '尾随零计数' = 't'
    '加法' = '+'; '减法' = '-'
    '乘法' = 'm'; '无符号除法' = 'd'; '无符号取余' = '%'
    '有符号除法' = 'D'; '有符号取余' = 'M'
}

$programmerBinaryOperations = @('a', 'o', 'x', 'q', '+', '-', 'm', 'd', '%', 'D', 'M')

function Format-ProgrammerOperand([long]$Value, [int]$Base) {
    if ($Base -eq 10) {
        return [BitConverter]::ToUInt64([BitConverter]::GetBytes($Value), 0).ToString($invariant)
    }
    return [Convert]::ToString($Value, $Base).ToUpperInvariant()
}

function Invoke-ProgrammerCalculation([hashtable]$Panel) {
    $Panel.UseResult.Enabled = $false
    $width = [int]$programmerWidths[[string]$Panel.Width.SelectedItem]
    $base = [string]$Panel.Base.SelectedItem
    $operation = $programmerOperations[[string]$Panel.Operation.SelectedItem]
    $left = $Panel.Left.Text.Trim()
    $right = $Panel.Right.Text.Trim()
    if ($operation -cin @('v', 'n', 'b', 'B', 'p', 'c', 't')) { $right = '' }
    $operandPattern = '\A[0-9A-Fa-fOoXx_-]{0,129}\z'
    $rightPattern = switch ($operation) {
        'f' { '\A[0-9]+:[0-9]+\z' }
        'i' { '\A[0-9]+:[0-9]+=[0-9A-Fa-fXx_]+\z' }
        default { $operandPattern }
    }
    if ($left -notmatch $operandPattern -or $right -notmatch $rightPattern) {
        $Panel.Result.Text = if ($operation -eq 'i') { '右值用十进制起点:长度=十六进制值。' } elseif ($operation -in @('f', 'F')) { '请在右值输入十进制起点:长度，例如 4:8。' } else {
            '请输入所选进制的数字。'
        }
        return
    }

    $response = Invoke-CalculatorCommand ('--programmer {0} {1} "{2}" "{3}" {4}' -f $base, $operation, $left, $right, $width)
    $Panel.Result.Text = $response.Text
    if (!$response.Success) { return }
    $value = [long]::Parse($response.Text, $invariant)
    $hex = [Convert]::ToString($value, 16).ToUpperInvariant().PadLeft([int]($width / 4), '0')
    $octal = [Convert]::ToString($value, 8)
    $binary = [Convert]::ToString($value, 2).PadLeft($width, '0')
    $unsigned = Format-ProgrammerOperand $value 10
    $signed = $value
    if ($width -lt 64 -and ($value -band (1L -shl ($width - 1)))) {
        $signed -= 1L -shl $width
    }
    $signedText = $signed.ToString($invariant)
    $Panel.Result.Text = "HEX  $hex`r`nDEC  $unsigned`r`nSIGNED  $signedText`r`nOCT  $octal`r`nBIN  $binary"
    $Panel.LastValue = $value
    $Panel.SignedValue = $signedText
    $Panel.UnsignedValue = $unsigned
    $Panel.UseResult.Enabled = $true
    $Panel.ToCalculator.Enabled = $signed -ge -2147483647 -and $signed -le 2147483647
    $Panel.UnsignedToCalculator.Enabled = $value -ge 0 -and $value -le 2147483647
}

function New-ProgrammerBitEditor([hashtable]$Panel) {
    $width = [int]$programmerWidths[[string]$Panel.Width.SelectedItem]
    $base = [int]$Panel.Base.SelectedItem
    $inputValue = $Panel.Left.Text.Trim()
    $operandPattern = '\A[0-9A-Fa-fOoXx_-]{1,129}\z'
    if ($inputValue -notmatch $operandPattern) {
        $Panel.Result.Text = '请输入所选进制的左操作数。'
        return
    }
    $response = Invoke-CalculatorCommand ('--programmer {0} v "{1}" "" {2}' -f $base, $inputValue, $width)
    if (!$response.Success) {
        $Panel.Result.Text = $response.Text
        return
    }
    $value = [long]::Parse($response.Text, $invariant)
    $binary = [Convert]::ToString($value, 2).PadLeft($width, '0')
    $window = [Windows.Forms.Form]::new()
    $window.Text = '编辑左操作数的位'
    $window.ClientSize = [Drawing.Size]::new(694, (86 + [int][math]::Ceiling($width / 16) * 48))
    $window.StartPosition = 'CenterParent'
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $window.BackColor = $form.BackColor
    $window.ForeColor = $form.ForeColor
    $window.Font = $form.Font
    $editor = @{ Window = $window; Parent = $Panel; Base = $base; Width = $width; Bits = @() }
    for ($index = 0; $index -lt $width; $index++) {
        $bit = [Windows.Forms.CheckBox]::new()
        $bit.Appearance = 'Button'
        $bit.TextAlign = 'MiddleCenter'
        $bit.Tag = $width - 1 - $index
        $bit.AccessibleName = "第 $($bit.Tag) 位"
        $bit.Checked = $binary[$index] -eq '1'
        $bit.Text = "$($bit.Tag)$([Environment]::NewLine)$([int]$bit.Checked)"
        $bit.SetBounds((12 + ($index % 16) * 42), (12 + [int][math]::Floor($index / 16) * 48), 40, 44)
        $bit.Add_CheckedChanged({
            param($sender, $eventArgs)
            $sender.Text = "$($sender.Tag)$([Environment]::NewLine)$([int]$sender.Checked)"
        })
        $window.Controls.Add($bit)
        $editor.Bits += $bit
    }
    $apply = [Windows.Forms.Button]::new()
    $apply.Text = '应用'
    $apply.SetBounds(582, ($window.ClientSize.Height - 58), 90, 34)
    $apply.Tag = $editor
    $apply.Add_Click({
        param($sender, $eventArgs)
        $dialog = $sender.Tag
        $bits = -join ($dialog.Bits | ForEach-Object { [int]$_.Checked })
        $response = Invoke-CalculatorCommand ('--programmer 2 v {0} "" {1}' -f $bits, $dialog.Width)
        if (!$response.Success) {
            $dialog.Parent.Result.Text = $response.Text
            $dialog.Window.Close()
            return
        }
        $value = [long]::Parse($response.Text, $invariant)
        $dialog.Parent.Left.Text = Format-ProgrammerOperand $value $dialog.Base
        $dialog.Parent.Result.Clear()
        $dialog.Window.Close()
    })
    $window.Controls.Add($apply)
    $window.AcceptButton = $apply
    $editor.Apply = $apply
    return $editor
}

function Switch-ProgrammerBase([hashtable]$Panel) {
    $nextBase = [int]$Panel.Base.SelectedItem
    if ($nextBase -eq $Panel.PreviousBase) { return }
    $width = [int]$programmerWidths[[string]$Panel.Width.SelectedItem]
    $operation = $programmerOperations[[string]$Panel.Operation.SelectedItem]
    $operands = @($Panel.Left)
    if ($operation -cin $programmerBinaryOperations) { $operands += $Panel.Right }
    $pattern = '\A[0-9A-Fa-fOoXx_-]{1,129}\z'
    $values = @()
    foreach ($operand in $operands) {
        $text = $operand.Text.Trim()
        if ($text -eq '') {
            $values += ''
            continue
        }
        if ($text -notmatch $pattern) {
            $Panel.Base.SelectedItem = [string]$Panel.PreviousBase
            $Panel.Result.Text = '进制未切换，请先修正操作数。'
            $Panel.UseResult.Enabled = $false
            return
        }
        $response = Invoke-CalculatorCommand ('--programmer {0} v "{1}" "" {2}' -f $Panel.PreviousBase, $text, $width)
        if (!$response.Success) {
            $Panel.Base.SelectedItem = [string]$Panel.PreviousBase
            $Panel.Result.Text = '进制未切换。' + $response.Text
            $Panel.UseResult.Enabled = $false
            return
        }
        $values += Format-ProgrammerOperand ([long]::Parse($response.Text, $invariant)) $nextBase
    }
    $Panel.PreviousBase = $nextBase
    for ($index = 0; $index -lt $operands.Count; $index++) {
        $operands[$index].Text = $values[$index]
    }
    $Panel.Result.Clear()
    $Panel.UseResult.Enabled = $false
}

function Import-StandardProgrammerOperand($Panel) {
    $Panel.UseResult.Enabled = $false
    if (!$state.CanCopy -or $state.InternalValue % 1000000000L -ne 0) {
        $Panel.Result.Text = '标准模式当前数值须为整数。'
        return
    }

    $value = [decimal]$state.InternalValue / 1000000000
    $width = [int]$programmerWidths[[string]$Panel.Width.SelectedItem]
    if ($width -lt 64) {
        $signBit = 1L -shl ($width - 1)
        if ($value -lt -$signBit -or $value -ge $signBit) {
            $Panel.Result.Text = '标准模式整数超出所选字长的有符号范围。'
            return
        }
    }
    $signedText = $value.ToString('0', $invariant)
    $response = Invoke-CalculatorCommand ('--programmer 10 v {0} "" {1}' -f $signedText, $width)
    if (!$response.Success) { $Panel.Result.Text = $response.Text; return }
    $base = [int]$Panel.Base.SelectedItem
    $Panel.Left.Text = if ($base -eq 10) { $signedText } else {
        Format-ProgrammerOperand ([long]::Parse($response.Text, $invariant)) $base
    }
    $Panel.Result.Clear()
    [void]$Panel.Left.Focus()
}

function Copy-ProgrammerResult($panel) {
    if (!$panel.CopyOperand.Enabled) { return }
    $base = [int]$panel.Base.SelectedItem
    $width = [int]$programmerWidths[[string]$panel.Width.SelectedItem]
    $digits = Format-ProgrammerOperand $panel.LastValue $base
    $value = switch ($base) {
        2 { '0b' + $digits.PadLeft($width, '0') }
        8 { '0o' + $digits }
        16 { '0x' + $digits.PadLeft([int]($width / 4), '0') }
        default { $digits }
    }
    try { & $copyToClipboard $value }
    catch [Runtime.InteropServices.ExternalException] {
        [void][Windows.Forms.MessageBox]::Show($panel.Window, '剪贴板正忙，请重试。')
    }
}

function Paste-ProgrammerOperand($Panel, $Target) {
    try { $value = ([string](& $readClipboard)).Trim() }
    catch [Runtime.InteropServices.ExternalException] {
        $Panel.Result.Text = '剪贴板正忙，请重试。'
        return
    }
    $base = [int]$Panel.Base.SelectedItem
    if ($value -match '\A0([xob])') {
        $base = switch ($Matches[1]) { 'x' { 16 }; 'o' { 8 }; 'b' { 2 } }
    }
    if ($value -notmatch '\A[0-9A-Fa-fOoXx_-]{1,129}\z') {
        $Panel.Result.Text = '请复制单个整数操作数。'
        return
    }
    $width = $programmerWidths[[string]$Panel.Width.SelectedItem]
    $response = Invoke-CalculatorCommand ('--programmer {0} v "{1}" "" {2}' -f $base, $value, $width)
    if (!$response.Success) { $Panel.Result.Text = $response.Text; return }
    $Target.Text = Format-ProgrammerOperand ([long]::Parse($response.Text, $invariant)) ([int]$Panel.Base.SelectedItem)
}

function Update-ProgrammerRightOperand($Panel) {
    $op = $programmerOperations[[string]$Panel.Operation.SelectedItem]
    $label = switch -CaseSensitive ($op) {
        { $_ -cin $programmerBinaryOperations } { '右操作数'; break }
        { $_ -cin @('l', 'r', 'h', 'L', 'R') } { '移位数（十进制）'; break }
        { $_ -cin @('f', 'F') } { '位字段起点:长度'; break }
        'i' { '位字段起点:长度=值'; break }
        default { '右值（未使用）' }
    }
    $Panel.Right.ReadOnly = $label -eq '右值（未使用）'
    $Panel.Right.TabStop = !$Panel.Right.ReadOnly
    $Panel.Right.AccessibleName = $label
    $Panel.RightLabel.Text = $label
}

function New-ProgrammerDialog {
    $window = [Windows.Forms.Form]::new()
    $window.Text = '白泽计算器 · 程序员'
    $window.ClientSize = [Drawing.Size]::new(724, 463)
    $window.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
    $window.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $window.MaximizeBox = $false
    $window.BackColor = $form.BackColor
    $window.ForeColor = $form.ForeColor
    $window.Font = $form.Font
    $controls = @{ Window = $window }

    $width = [Windows.Forms.ComboBox]::new()
    $width.Items.AddRange([object[]]@($programmerWidths.Keys))
    $width.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $width.SelectedItem = 'DWORD'
    $width.AccessibleDescription = 'Ctrl+Shift+1 BYTE，Ctrl+Shift+2 WORD，Ctrl+Shift+3 DWORD，Ctrl+Shift+4 QWORD'
    $base = [Windows.Forms.ComboBox]::new()
    $base.Items.AddRange([object[]]@('16', '10', '8', '2'))
    $base.AccessibleDescription = 'Ctrl+1 十六进制，Ctrl+2 十进制，Ctrl+3 八进制，Ctrl+4 二进制'
    $window.KeyPreview = $true
    $window.Tag = $controls
    $window.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::C -and
            $eventArgs.Modifiers -eq ([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Shift)) {
            Copy-ProgrammerResult $sender.Tag
            $eventArgs.SuppressKeyPress = $true
            return
        }
        $index = [int]$eventArgs.KeyCode - [int][Windows.Forms.Keys]::D1
        if ($index -lt 0 -or $index -gt 3) { return }
        $selector = switch ($eventArgs.Modifiers) {
            ([Windows.Forms.Keys]::Control) { $sender.Tag.Base }
            ([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Shift) { $sender.Tag.Width }
        }
        if ($null -ne $selector) {
            $selector.SelectedIndex = $index
            $eventArgs.SuppressKeyPress = $true
        }
    })
    $base.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $base.SelectedIndex = 0
    $operation = [Windows.Forms.ComboBox]::new()
    $operation.Items.AddRange([object[]]@($programmerOperations.Keys))
    $operation.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $operation.SelectedIndex = 0

    $left = [Windows.Forms.TextBox]::new()
    $left.Text = '0'
    $left.MaxLength = 129
    $right = [Windows.Forms.TextBox]::new()
    $right.Text = '0'
    $right.MaxLength = 129
    $row = 0
    foreach ($field in @(
        @{ Key = 'Width'; Label = '字长'; Element = $width },
        @{ Key = 'Base'; Label = '进制'; Element = $base },
        @{ Key = 'Operation'; Label = '运算'; Element = $operation },
        @{ Key = 'Left'; Label = '左操作数'; Element = $left },
        @{ Key = 'Right'; Label = '右值 / 移位数'; Element = $right }
    )) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $field.Label
        $label.SetBounds(16, 16 + 40 * $row, 132, 29)
        $field.Element.SetBounds(155, 16 + 40 * $row, 552, 29)
        $field.Element.AccessibleName = $field.Label
        $window.Controls.Add($label)
        $window.Controls.Add($field.Element)
        $controls[$field.Key] = $field.Element
        if ($field.Key -eq 'Right') { $controls.RightLabel = $label }
        $row++
    }

    $result = [Windows.Forms.TextBox]::new()
    $result.SetBounds(16, 265, 690, 142)
    $result.ReadOnly = $true
    $result.Multiline = $true
    $result.WordWrap = $false
    $result.ScrollBars = [Windows.Forms.ScrollBars]::Horizontal
    $result.BackColor = [Drawing.ColorTranslator]::FromHtml('#243138')
    $result.ForeColor = $window.ForeColor
    $result.Font = [Drawing.Font]::new('Consolas', 12)
    $result.AccessibleName = '四种进制和有符号十进制结果'
    $window.Controls.Add($result)
    $controls.Result = $result

    $hint = [Windows.Forms.Label]::new()
    $hint.Text = '十进制支持负数 · 移位数用十进制'
    $hint.SetBounds(16, 224, 330, 34)
    $window.Controls.Add($hint)
    $hint.Tag = $hint.Text
    $controls.FieldHint = $hint
    $operation.Tag = $controls
    $operation.Add_SelectedIndexChanged({
        param($sender, $eventArgs)
        $currentHint = $sender.Tag.FieldHint
        $currentHint.Text = if ($sender.SelectedItem -eq '写入位字段') { '右值示例 4:8=0x42（写入十六进制 42）' } elseif ($sender.SelectedItem -in @('提取位字段', '提取有符号位字段')) { '右值用十进制起点:长度，例如 4:8' } else {
            $currentHint.Tag
        }
    })
    $submit = [Windows.Forms.Button]::new()
    $submit.Text = '计算'
    $editBits = [Windows.Forms.Button]::new()
    $editBits.Text = '编辑左值位'
    $editBits.SetBounds(476, 218, 130, 36)
    $editBits.Tag = $controls
    $editBits.Add_Click({
        param($sender, $eventArgs)
        $editor = New-ProgrammerBitEditor $sender.Tag
        if ($null -eq $editor) { return }
        try { [void]$editor.Window.ShowDialog($sender.Tag.Window) }
        finally { $editor.Window.Dispose() }
    })
    $window.Controls.Add($editBits)
    $useResult = [Windows.Forms.Button]::new()
    $useResult.Text = '使用结果'
    $useResult.SetBounds(346, 218, 118, 36)
    $useResult.Enabled = $false
    $useResult.Tag = $controls
    $useResult.Add_Click({
        param($sender, $eventArgs)
        if (!$sender.Enabled) { return }
        $panel = $sender.Tag
        $base = [int]$panel.Base.SelectedItem
        $panel.Left.Text = Format-ProgrammerOperand $panel.LastValue $base
        $panel.Result.Clear()
        $sender.Enabled = $false
        [void]$panel.Left.Focus()
    })
    $window.Controls.Add($useResult)
    $controls.UseResult = $useResult
    $copyOperand = [Windows.Forms.Button]::new()
    $copyOperand.Text = '复制当前进制'
    $copyOperand.SetBounds(16, 415, 166, 36)
    $copyOperand.Enabled = $false
    $copyOperand.Tag = $controls
    $copyOperand.Add_Click({ param($sender, $eventArgs) Copy-ProgrammerResult $sender.Tag })
    $window.Controls.Add($copyOperand)
    $controls.CopyOperand = $copyOperand
    Add-StandardTransferButton $controls 418 -X 194 -Text '有符号值带回标准模式' -ValueKey 'SignedValue'
    Add-StandardTransferButton $controls 418 -X 550 -Text '无符号值带回标准模式' -ValueKey 'UnsignedValue' -ButtonKey 'UnsignedToCalculator'
    $fromCalculator = [Windows.Forms.Button]::new()
    $fromCalculator.Text = '从标准模式取整数'
    $fromCalculator.SetBounds(372, 418, 166, 30)
    $fromCalculator.Tag = $controls
    $fromCalculator.Add_Click({ param($sender, $eventArgs) Import-StandardProgrammerOperand $sender.Tag })
    $window.Controls.Add($fromCalculator)
    $controls.FromCalculator = $fromCalculator
    $useResult.Add_EnabledChanged({
        param($sender, $eventArgs)
        $sender.Tag.CopyOperand.Enabled = $sender.Enabled
        if (!$sender.Enabled) {
            $sender.Tag.ToCalculator.Enabled = $false
            $sender.Tag.UnsignedToCalculator.Enabled = $false
        }
    })
    $invalidateResult = {
        param($sender, $eventArgs)
        $panel = $sender.Tag
        $panel.Result.Clear()
        $panel.UseResult.Enabled = $false
    }
    foreach ($selector in @($width, $operation)) {
        $selector.Tag = $controls
        $selector.Add_SelectedIndexChanged($invalidateResult)
    }
    $operation.Add_SelectedIndexChanged({ param($sender, $eventArgs) Update-ProgrammerRightOperand $sender.Tag })
    Update-ProgrammerRightOperand $controls
    $controls.PreviousWidth = [int]$programmerWidths[[string]$width.SelectedItem]
    $width.Add_SelectedIndexChanged({
        param($sender, $eventArgs)
        $panel = $sender.Tag
        $next = [int]$programmerWidths[[string]$sender.SelectedItem]
        $previous = $panel.PreviousWidth
        $panel.PreviousWidth = $next
        if ($next -ge $previous) { return }
        $inputs = @($panel.Left)
        $op = $programmerOperations[[string]$panel.Operation.SelectedItem]
        if ($op -cin $programmerBinaryOperations) { $inputs += $panel.Right }
        foreach ($inputBox in $inputs) {
            $operand = $inputBox.Text.Trim()
            if ($operand -notmatch '\A[0-9A-Fa-fOoXx_-]{1,129}\z') { continue }
            $response = Invoke-CalculatorCommand ('--programmer {0} v "{1}" "" {2}' -f $panel.Base.SelectedItem, $operand, $next)
            if (!$response.Success) {
                $panel.Result.Text = '请检查新字长下的操作数：' + $response.Text
                return
            }
        }
    })
    $controls.PreviousBase = [int]$base.SelectedItem
    $base.Tag = $controls
    $base.Add_SelectedIndexChanged({ param($sender, $eventArgs) Switch-ProgrammerBase $sender.Tag })
    foreach ($operand in @($left, $right)) {
        $operand.Tag = $controls
        $operand.Add_TextChanged($invalidateResult)
        $operand.Add_KeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.KeyCode -ne [Windows.Forms.Keys]::V -or
                $eventArgs.Modifiers -ne ([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Shift)) { return }
            $panel = $sender.Tag
            $op = $programmerOperations[[string]$panel.Operation.SelectedItem]
            if ($sender -eq $panel.Right -and $op -cnotin $programmerBinaryOperations) { return }
            Paste-ProgrammerOperand $panel $sender
            $eventArgs.SuppressKeyPress = $true
        })
    }
    $submit.SetBounds(618, 218, 88, 36)
    $submit.ForeColor = $window.BackColor
    $submit.BackColor = [Drawing.ColorTranslator]::FromHtml('#F1C56C')
    $submit.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $submit.Tag = $controls
    $submit.Add_Click({ param($sender, $eventArgs) Invoke-ProgrammerCalculation $sender.Tag })
    $window.Controls.Add($submit)
    $window.AcceptButton = $submit
    $controls.Submit = $submit
    return $controls
}

$programmerButton = New-CalculatorActionButton '程序员模式' 16 609 160
$programmerButton.Add_Click({
    $panel = New-ProgrammerDialog
    try { [void]$panel.Window.ShowDialog($form) }
    finally { $panel.Window.Dispose() }
})

$converterUnits = [ordered]@{
    '长度' = @{ FirstId = 1; Names = @('毫米', '厘米', '米', '千米', '英寸', '英尺', '码', '英里') }
    '温度' = @{ FirstId = 9; Names = @('华氏度', '开尔文', '摄氏度') }
    '质量' = @{ FirstId = 12; Names = @('毫克', '克', '千克', '磅', '盎司', '斤') }
    '速度' = @{ FirstId = 18; Names = @('米/秒', '千米/小时', '英里/小时', '节') }
    '时间' = @{ FirstId = 22; Names = @('毫秒', '秒', '分钟', '小时', '天', '周', '年（365 天）') }
    '数据容量' = @{ FirstId = 29; Names = @('位 (bit)', '字节 (B)', '千字节 (kB)', '兆字节 (MB)', '吉字节 (GB)', '太字节 (TB)', 'KiB', 'MiB', 'GiB', 'TiB') }
    '面积' = @{ FirstId = 39; Names = @('平方厘米', '平方米', '公顷', '平方千米', '市亩', '平方英寸', '平方英尺', '平方码', '英亩') }
    '体积' = @{ FirstId = 48; Names = @('毫升', '升', '立方米', '美制加仑', '英制加仑', '美制杯', '美制液量盎司', '英制液量盎司') }
    '压力' = @{ FirstId = 56; Names = @('帕 (Pa)', '千帕 (kPa)', '兆帕 (MPa)', '巴 (bar)', '标准大气压 (atm)', '磅力/平方英寸 (PSI)', '托 (Torr)') }
    '能量' = @{ FirstId = 63; Names = @('焦 (J)', '千焦 (kJ)', '兆焦 (MJ)', '瓦时 (Wh)', '千瓦时 (kWh)', '热化学卡 (cal)', '热化学千卡 (kcal)') }
    '功率' = @{ FirstId = 70; Names = @('瓦 (W)', '千瓦 (kW)', '兆瓦 (MW)', '机械马力 (hp)', '公制马力 (PS)') }
    '频率' = @{ FirstId = 75; Names = @('赫兹 (Hz)', '千赫 (kHz)', '兆赫 (MHz)', '吉赫 (GHz)', '转/分钟 (RPM)') }
    '角度' = @{ FirstId = 80; Names = @('度 (°)', '弧度 (rad)', '百分度 (gon)', '圈', '角分', '角秒') }
    '油耗' = @{ FirstId = 86; Names = @('升/百公里', '千米/升', '英里/美制加仑', '英里/英制加仑') }
    '网络速率' = @{ FirstId = 90; Names = @('bit/s', 'kbit/s', 'Mbit/s', 'Gbit/s', 'B/s', 'kB/s', 'MB/s', 'GB/s', 'KiB/s', 'MiB/s', 'GiB/s') }
    '加速度' = @{ FirstId = 101; Names = @('m/s²', 'cm/s² (Gal)', 'mm/s²', 'ft/s²', '标准重力 (g₀)') }
    '力' = @{ FirstId = 106; Names = @('牛顿 (N)', '千牛 (kN)', '达因 (dyn)', '千克力 (kgf)', '磅力 (lbf)') }
    '扭矩' = @{ FirstId = 111; Names = @('牛顿米 (N·m)', '牛顿厘米 (N·cm)', '千克力米 (kgf·m)', '磅力英尺 (lbf·ft)', '磅力英寸 (lbf·in)') }
}

function Switch-ConverterUnits($Panel) {
    $fromIndex = $Panel.From.SelectedIndex
    $Panel.From.SelectedIndex = $Panel.To.SelectedIndex
    $Panel.To.SelectedIndex = $fromIndex
    $Panel.Result.Clear()
    $Panel.Reverse.Enabled = $false
}

function Invoke-UnitConversion($Panel) {
    $Panel.Timer.Stop()
    $Panel.Reverse.Enabled = $false
    $Panel.ToCalculator.Enabled = $false
    $value = $Panel.Input.Text.Trim()
    if ($value -notmatch '\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z') {
        $Panel.Result.Text = '换算错误：请输入有效数值，小数点使用 .'
        return
    }
    $firstId = $converterUnits[[string]$Panel.Category.SelectedItem].FirstId
    $sourceId = $firstId + $Panel.From.SelectedIndex
    $targetId = $firstId + $Panel.To.SelectedIndex
    $response = Invoke-CalculatorCommand ('--convert-text {0} {1} "{2}"' -f $sourceId, $targetId, $value)
    $Panel.Result.Text = $response.Text
    if ($response.Success) {
        $number = [decimal]::Parse($response.Text, $invariant)
        $Panel.LastValue = $response.Text
        $Panel.Result.Text = $Panel.LastValue + ' ' + $Panel.To.SelectedItem
        $Panel.ToCalculator.Enabled = [math]::Abs($number) -le 2147483647
        $Panel.Reverse.Enabled = [math]::Abs($number) -le 1000000000 -and
            ($number -ne 0 -or $Panel.Category.SelectedItem -ne '油耗')
    }
}

function Invoke-CalculatorCommand([string]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $workerPath
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($start)
    try {
        $read = $process.StandardOutput.ReadToEndAsync()
        if (!$process.WaitForExit(2000)) {
            $process.Kill()
            return @{ Success = $false; Text = '计算进程未及时返回。' }
        }
        return @{ Success = ($process.ExitCode -eq 0); Text = $read.GetAwaiter().GetResult().Trim() }
    } finally {
        $process.Dispose()
    }
}

function Get-ConverterComparison($Panel) {
    $value = $Panel.Input.Text.Trim()
    if ($value -notmatch '\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z') {
        return @{ Success = $false; Text = '换算错误：请输入有效数值，小数点使用 .' }
    }
    $units = $converterUnits[[string]$Panel.Category.SelectedItem]
    $source = $units.FirstId + $Panel.From.SelectedIndex
    $response = Invoke-CalculatorCommand ('--convert-text {0} all "{1}"' -f $source, $value)
    if (!$response.Success) { return $response }
    $lines = $response.Text -split '\r?\n'
    if ($lines.Count -ne 2 * $units.Names.Count) { throw '同类单位换算结果数量错误' }
    $rows = for ($index = 0; $index -lt $units.Names.Count; $index++) {
        $display = '超出范围'
        if ($lines[2 * $index] -eq '0') {
            $display = $lines[2 * $index + 1]
        }
        $value = if ($lines[2 * $index] -eq '0') { $display }
        [pscustomobject]@{ Text = "$display  $($units.Names[$index])"; Value = $value }
    }
    return @{ Success = $true; Rows = $rows; Text = ($rows.Text -join [Environment]::NewLine) }
}

function Add-StandardTransferButton($Panel, [int]$Y, [int]$X = 16, [string]$Text = '用作标准模式输入', [string]$ValueKey = 'LastValue', [string]$ButtonKey = 'ToCalculator') {
    $toCalculator = [Windows.Forms.Button]::new()
    $toCalculator.Text = $Text
    $toCalculator.SetBounds($X, $Y, 166, 30)
    $toCalculator.Enabled = $false
    $toCalculator.Tag = @{ Panel = $Panel; ValueKey = $ValueKey }
    $toCalculator.Add_Click({
        param($sender, $eventArgs)
        if (!$sender.Enabled) { return }
        $controls = $sender.Tag.Panel
        $response = Apply-CalculatorCommand ("P{0}{1}" -f $controls[$sender.Tag.ValueKey], [char]10) -PassThru
        if ($null -eq $response -or $response.Code -ne 0) {
            $sender.Text = '带入失败，重试'
            return
        }
        $controls.Transferred = $true
        $controls.Window.Close()
    })
    $Panel.Window.Controls.Add($toCalculator)
    $Panel[$ButtonKey] = $toCalculator
}

function New-ConverterComparisonDialog([string]$Category, $Comparison) {
    $window = [Windows.Forms.Form]::new()
    $window.Text = '同类单位换算 · ' + $Category
    $window.StartPosition = 'CenterParent'
    $window.FormBorderStyle = 'FixedDialog'
    $window.ClientSize = [Drawing.Size]::new(390, 330)
    $window.Font = $form.Font

    $values = [Windows.Forms.ListBox]::new()
    $values.SetBounds(12, 12, 366, 264)
    $values.DisplayMember = 'Text'
    $values.Items.AddRange([object[]]$Comparison.Rows)
    $window.Controls.Add($values)

    $panel = @{ Window = $window; Values = $values; Transferred = $false }
    Add-StandardTransferButton $panel 288 132
    $values.Tag = $panel
    $values.Add_SelectedIndexChanged({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $controls.LastValue = $sender.SelectedItem.Value
        $controls.ToCalculator.Enabled = $null -ne $controls.LastValue -and
            [math]::Abs([decimal]::Parse($controls.LastValue, $invariant)) -le 2147483647
    })

    $copy = [Windows.Forms.Button]::new()
    $copy.Text = '复制全部'
    $copy.SetBounds(12, 288, 112, 30)
    $copy.Tag = $Comparison.Text
    $copy.Add_Click({
        param($sender, $eventArgs)
        try {
            & $copyToClipboard $sender.Tag
            $sender.Text = '已复制'
        } catch [Runtime.InteropServices.ExternalException] {
            $sender.Text = '复制失败，重试'
        }
    })
    $window.Controls.Add($copy)
    $panel.Copy = $copy
    return $panel
}

function New-ConverterDialog {
    $window = [Windows.Forms.Form]::new()
    $window.Text = '白泽计算器 · 单位换算'
    $window.ClientSize = [Drawing.Size]::new(430, 268)
    $window.StartPosition = 'CenterParent'
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $window.BackColor = $form.BackColor
    $window.ForeColor = $form.ForeColor
    $window.Font = $form.Font

    $panel = @{ Window = $window }
    $fields = @(
        @{ Key = 'Category'; Caption = '类别'; Kind = 'ComboBox'; X = 16; Y = 16 },
        @{ Key = 'Input'; Caption = '数值'; Kind = 'TextBox'; X = 222; Y = 16 },
        @{ Key = 'From'; Caption = '来源单位'; Kind = 'ComboBox'; X = 16; Y = 80 },
        @{ Key = 'To'; Caption = '目标单位'; Kind = 'ComboBox'; X = 222; Y = 80 }
    )
    foreach ($field in $fields) {
        $caption = [Windows.Forms.Label]::new()
        $caption.Text = $field.Caption
        $caption.SetBounds($field.X, $field.Y, 190, 22)
        $window.Controls.Add($caption)
        $control = New-Object "Windows.Forms.$($field.Kind)"
        $control.SetBounds($field.X, ($field.Y + 24), 190, 32)
        if ($field.Kind -eq 'ComboBox') { $control.DropDownStyle = 'DropDownList' }
        $window.Controls.Add($control)
        $panel[$field.Key] = $control
    }
    $panel.Input.MaxLength = 32
    $panel.Category.Tag = $panel
    $panel.Category.Add_SelectedIndexChanged({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $items = [object[]]$converterUnits[[string]$sender.SelectedItem].Names
        foreach ($selector in @($controls.From, $controls.To)) {
            $selector.Items.Clear()
            $selector.Items.AddRange($items)
        }
        $controls.From.SelectedIndex = 0
        $controls.To.SelectedIndex = 1
        $controls.Result.Text = ''
    })
    $result = [Windows.Forms.TextBox]::new()
    $result.ReadOnly = $true
    $result.SetBounds(16, 153, 296, 32)
    $window.Controls.Add($result)
    $panel.Result = $result
    $submit = [Windows.Forms.Button]::new()
    $submit.Text = '换算'
    $submit.SetBounds(324, 151, 88, 34)
    $submit.ForeColor = $window.BackColor
    $submit.BackColor = [Drawing.ColorTranslator]::FromHtml('#F1C56C')
    $submit.FlatStyle = 'Flat'
    $submit.Tag = $panel
    $submit.Add_Click({ param($sender, $eventArgs) Invoke-UnitConversion $sender.Tag })
    $window.Controls.Add($submit)
    $window.AcceptButton = $submit
    $panel.Submit = $submit
    $swap = [Windows.Forms.Button]::new()
    $swap.Text = '交换单位'
    $swap.SetBounds(324, 188, 88, 28)
    $swap.Tag = $panel
    $swap.Add_Click({
        param($sender, $eventArgs)
        Switch-ConverterUnits $sender.Tag
    })
    $window.Controls.Add($swap)
    $panel.Swap = $swap
    $reverse = [Windows.Forms.Button]::new()
    $reverse.Text = '反向换算'
    $reverse.SetBounds(214, 188, 98, 28)
    $reverse.Enabled = $false
    $reverse.Tag = $panel
    $reverse.Add_Click({
        param($sender, $eventArgs)
        if (!$sender.Enabled) { return }
        $controls = $sender.Tag
        $resultValue = $controls.LastValue
        Switch-ConverterUnits $controls
        $controls.Input.Text = $resultValue
        Invoke-UnitConversion $controls
    })
    $window.Controls.Add($reverse)
    $panel.Reverse = $reverse
    Add-StandardTransferButton $panel 223
    $compare = [Windows.Forms.Button]::new()
    $compare.Text = '全部单位'
    $compare.SetBounds(122, 188, 86, 28)
    $compare.Tag = $panel
    $compare.Add_Click({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $response = Get-ConverterComparison $controls
        if (!$response.Success) {
            $controls.Result.Text = $response.Text
            $controls.Reverse.Enabled = $false
            $controls.ToCalculator.Enabled = $false
            return
        }
        $results = New-ConverterComparisonDialog $controls.Category.SelectedItem $response
        try { [void]$results.Window.ShowDialog($controls.Window) }
        finally { $results.Window.Dispose() }
        if ($results.Transferred) { $controls.Window.Close() }
    })
    $window.Controls.Add($compare)
    $auto = [Windows.Forms.CheckBox]::new()
    $auto.Text = '自动更新'
    $auto.SetBounds(16, 188, 106, 28)
    $window.Controls.Add($auto)
    $panel.Auto = $auto
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 250
    $timer.Tag = $panel
    $timer.Add_Tick({
        param($sender, $eventArgs)
        $sender.Stop()
        $controls = $sender.Tag
        if (!$controls.Auto.Checked -or $controls.Input.Text.Trim() -eq '' -or
            $controls.From.SelectedIndex -lt 0 -or $controls.To.SelectedIndex -lt 0) { return }
        Invoke-UnitConversion $controls
    })
    $panel.Timer = $timer
    $window.Tag = $panel
    $window.Add_Disposed({ param($sender, $eventArgs) $sender.Tag.Timer.Dispose() })
    $auto.Tag = $panel
    $auto.Add_CheckedChanged({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $controls.Timer.Stop()
        if ($sender.Checked) { $controls.Timer.Start() }
    })
    $clearResult = {
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $controls.Result.Clear()
        $controls.Reverse.Enabled = $false
        $controls.ToCalculator.Enabled = $false
        $controls.Timer.Stop()
        if ($controls.Auto.Checked) { $controls.Timer.Start() }
    }
    foreach ($selector in @($panel.From, $panel.To)) {
        $selector.Tag = $panel
        $selector.Add_SelectedIndexChanged($clearResult)
    }
    $panel.Input.Tag = $panel
    $panel.Input.Add_TextChanged($clearResult)
    $panel.Category.Items.AddRange([object[]]@($converterUnits.Keys))
    $panel.Category.SelectedIndex = 0
    if ($state.CanCopy) {
        $displayed = $resultLabel.Text.Replace(',', '')
        $numeric = [decimal]0
        if ([decimal]::TryParse($displayed, [Globalization.NumberStyles]::Number, $invariant, [ref]$numeric) -and
            [math]::Abs($numeric) -le 1000000000) {
            $exact = [decimal]$state.InternalValue / 1000000000
            if ([math]::Abs($exact) -le 1000000000) {
                $panel.Input.Text = if ($numeric -eq $exact) { $displayed } else { Format-BaizeInternalValue $state.InternalValue }
            }
        }
    }
    return $panel
}

$converterButton = New-CalculatorActionButton '单位换算' 186 609 160
$converterButton.Add_Click({
    $panel = New-ConverterDialog
    try { [void]$panel.Window.ShowDialog($form) }
    finally { $panel.Window.Dispose() }
})

$dateSession = @{ WorkdayExceptions = '' }

function Invoke-DateCalculation($Panel) {
    $Panel.UseResult.Enabled = $false
    $startDate = $Panel.Start.Text.Trim()
    $operand = $Panel.Operand.Text.Trim()
    if ($Panel.Mode.SelectedIndex -eq 13) {
        $weekday = $Panel.Months.Text.Trim()
        if ($startDate -notmatch '\A[0-9]{1,4}\z' -or $operand -notmatch '\A[0-9]{1,2}\z' -or $weekday -notmatch '\A[1-7]\z') {
            $Panel.Result.Text = '请输入周年、周数和星期（1–7）。'
            return
        }
        $response = Invoke-CalculatorCommand "--date W $startDate $operand $weekday"
        if (!$response.Success) { $Panel.Result.Text = $response.Text; return }
        $Panel.Result.Text = $response.Text.PadLeft(8, '0').Insert(6, '-').Insert(4, '-')
        $Panel.UseResult.Enabled = $true
        return
    }
    $operation = @('c', 'a', 's', 'a', 's', 'a', 's', 'a', 's', 'w', 'b', 'a', 's', '', 'a', 's')[$Panel.Mode.SelectedIndex]
    $unit = @('', '', '', 'm', 'm', 'y', 'y', '', '', '', '', 'b', 'b', '', 'w', 'w')[$Panel.Mode.SelectedIndex]
    if ($startDate -notmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z' -or
        ($operation -in @('c', 'b') -and $operand -notmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z')) {
        $Panel.Result.Text = '日期格式为 YYYY-MM-DD。'
        return
    }
    if ($operation -in @('a', 's') -and $operand -notmatch '\A[0-9]+\z') {
        $Panel.Result.Text = '请输入非负整数。'
        return
    }
    $arguments = '--date {0} {1}' -f $operation, $startDate.Replace('-', '')
    if ($operation -ne 'w') { $arguments += ' ' + $operand.Replace('-', '') }
    if ($Panel.MonthEnd.Checked) {
        if ($unit -eq 'm') { $unit = 'e' }
        if ($unit -eq 'y') { $unit = 'E' }
    }
    if ($unit) { $arguments += ' ' + $unit }
    $usesWorkdays = $Panel.Mode.SelectedIndex -in @(10, 11, 12)
    if ($usesWorkdays) {
        $exceptions = $Panel.WorkdayExceptions.Text.Trim()
        if ($exceptions) {
            $exceptionDates = @($exceptions -split ',' | ForEach-Object { $_.Trim() })
            if ($exceptionDates.Count -gt 32 -or
                @($exceptionDates | Where-Object { $_ -notmatch '\A[+-][0-9]{4}-[0-9]{2}-[0-9]{2}\z' }).Count -gt 0) {
                $Panel.Result.Text = '例外日期用 -YYYY-MM-DD 或 +YYYY-MM-DD，以逗号分隔。'
                return
            }
            $arguments += ' ' + (($exceptionDates -join ',') -replace '(?<=\d)-(?=\d)', '')
        }
    }
    if ($Panel.Mode.SelectedIndex -in @(7, 8)) {
        $months = $Panel.Months.Text.Trim()
        $days = $Panel.Days.Text.Trim()
        if ($months -notmatch '\A[0-9]+\z' -or $days -notmatch '\A[0-9]+\z') {
            $Panel.Result.Text = '年、月、日须为非负整数。'
            return
        }
        $arguments += ' {0} {1}' -f $months, $days
    }
    $response = Invoke-CalculatorCommand $arguments
    $Panel.Result.Text = $response.Text
    if ($response.Success) {
        if ($usesWorkdays) { $dateSession.WorkdayExceptions = $exceptions }
        if ($operation -eq 'w') {
            $parts = $response.Text -split '\r?\n'
            $weekday = @('一', '二', '三', '四', '五', '六', '日')[[int]$parts[2] - 1]
            $Panel.Result.Text = ("星期{0}{3}{1} 年第 {2} 周" -f $weekday, $parts[0], $parts[1], [Environment]::NewLine)
            $Panel.IsoWeekParts = $parts
            $Panel.UseResult.Enabled = $true
        } elseif ($operation -eq 'b') {
            $Panel.Result.Text = $response.Text + ' 个工作日'
        } elseif ($operation -eq 'c') {
            $parts = $response.Text -split '\r?\n'
            $Panel.Result.Text = ("{0} 年 {1} 个月 {2} 天{4}共 {3} 天" -f ($parts + [Environment]::NewLine))
        } else {
            $date = $response.Text.PadLeft(8, '0')
            $Panel.Result.Text = $date.Insert(6, '-').Insert(4, '-')
            $Panel.UseResult.Enabled = $true
        }
    }
}

function New-CalculatorDatePicker([Windows.Forms.TextBox]$Target) {
    $window = [Windows.Forms.Form]::new()
    $window.Text = '选择公历日期'
    $window.StartPosition = 'CenterParent'
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $window.MinimizeBox = $false
    $calendar = [Windows.Forms.MonthCalendar]::new()
    $calendar.MaxSelectionCount = 1
    $calendar.SetBounds(12, 12, $calendar.Width, $calendar.Height)
    $date = [DateTime]::Today
    $selected = [DateTime]::MinValue
    if ([DateTime]::TryParseExact($Target.Text.Trim(), 'yyyy-MM-dd', $invariant, [Globalization.DateTimeStyles]::None, [ref]$selected)) {
        if ($selected -ge $calendar.MinDate -and $selected -le $calendar.MaxDate) { $date = $selected }
    }
    $calendar.SetDate($date)
    $window.Controls.Add($calendar)

    $select = [Windows.Forms.Button]::new()
    $select.Text = '选定日期'
    $select.SetBounds(12, ($calendar.Bottom + 10), $calendar.Width, 32)
    $select.Tag = @{ Target = $Target; Calendar = $calendar; Window = $window }
    $select.Add_Click({
        param($sender, $eventArgs)
        $dialog = $sender.Tag
        $dialog.Target.Text = $dialog.Calendar.SelectionStart.ToString('yyyy-MM-dd', $invariant)
        $dialog.Window.Close()
    })
    $window.Controls.Add($select)
    $window.AcceptButton = $select
    $window.ClientSize = [Drawing.Size]::new(($calendar.Right + 12), ($select.Bottom + 12))
    return @{ Window = $window; Calendar = $calendar; Select = $select }
}

function New-DateDialog {
    $window = [Windows.Forms.Form]::new()
    $window.Text = '白泽计算器 · 日期计算'
    $window.ClientSize = [Drawing.Size]::new(410, 273)
    $window.StartPosition = 'CenterParent'
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $window.BackColor = $form.BackColor
    $window.ForeColor = $form.ForeColor
    $window.Font = $form.Font
    $panel = @{ Window = $window }
    $mode = [Windows.Forms.ComboBox]::new()
    $mode.DropDownStyle = 'DropDownList'
    $mode.Items.AddRange([object[]]@('相隔日期', '加天数', '减天数', '加月数', '减月数', '加年数', '减年数', '加年/月/日', '减年/月/日', '星期与周数', '相隔工作日', '加工作日', '减工作日', '按 ISO 周查日期', '加周数', '减周数'))
    $mode.SetBounds(16, 16, 378, 32)
    $window.Controls.Add($mode)
    $panel.Mode = $mode
    foreach ($field in @(@{ Key = 'Start'; X = 16 }, @{ Key = 'Operand'; X = 212 })) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = '起始日期'
        $label.SetBounds($field.X, 59, 182, 23)
        $window.Controls.Add($label)
        $inputBox = [Windows.Forms.TextBox]::new()
        $inputBox.MaxLength = 10
        $inputBox.SetBounds($field.X, 84, 182, 31)
        $window.Controls.Add($inputBox)
        $panel[$field.Key] = $inputBox
        $panel[$field.Key + 'Label'] = $label
    }
    foreach ($field in @(@{ Key = 'Start'; X = 16; Label = '选择起始日期' }, @{ Key = 'Operand'; X = 212; Label = '选择结束日期' })) {
        $button = [Windows.Forms.Button]::new()
        $button.Text = '日历'
        $button.AccessibleName = $field.Label
        $button.SetBounds(($field.X + 133), 82, 49, 31)
        $button.Tag = $panel[$field.Key]
        $button.Add_Click({
            param($sender, $eventArgs)
            $picker = New-CalculatorDatePicker $sender.Tag
            try { [void]$picker.Window.ShowDialog($sender.FindForm()) }
            finally { $picker.Window.Dispose() }
        })
        $window.Controls.Add($button)
        $panel[$field.Key + 'Calendar'] = $button
    }
    $panel.Start.Width = 129
    $panel.Start.Text = [DateTime]::Today.ToString('yyyy-MM-dd', $invariant)
    foreach ($field in @(@{ Key = 'Months'; Text = '月数'; X = 16 }, @{ Key = 'Days'; Text = '天数'; X = 212 })) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $field.Text
        $label.SetBounds($field.X, 119, 182, 23)
        $window.Controls.Add($label)
        $box = [Windows.Forms.TextBox]::new()
        $box.MaxLength = 10
        $box.SetBounds($field.X, 144, 182, 31)
        $box.Text = '0'
        $window.Controls.Add($box)
        $panel[$field.Key] = $box
        $panel[$field.Key + 'Label'] = $label
    }
    $result = [Windows.Forms.TextBox]::new()
    $result.ReadOnly = $true
    $result.Multiline = $true
    $result.SetBounds(16, 194, 280, 56)
    $monthEnd = [Windows.Forms.CheckBox]::new()
    $monthEnd.Text = '起始日为月末时，结果也取月末'
    $monthEnd.SetBounds(16, 144, 378, 31)
    $monthEnd.Visible = $false
    $monthEnd.Tag = $panel
    $monthEnd.Add_CheckedChanged({
        param($sender, $eventArgs)
        $sender.Tag.Result.Clear()
        $sender.Tag.UseResult.Enabled = $false
    })
    $panel.MonthEnd = $monthEnd
    $window.Controls.Add($monthEnd)
    $workdayLabel = [Windows.Forms.Label]::new()
    $workdayLabel.Text = '例外日期（- 休息，+ 上班，逗号分隔）'
    $workdayLabel.SetBounds(16, 119, 378, 23)
    $workdayLabel.Visible = $false
    $window.Controls.Add($workdayLabel)
    $workdayExceptions = [Windows.Forms.TextBox]::new()
    $workdayExceptions.MaxLength = 400
    $workdayExceptions.Text = $dateSession.WorkdayExceptions
    $workdayExceptions.AccessibleName = $workdayLabel.Text
    $workdayExceptions.SetBounds(16, 144, 378, 31)
    $workdayExceptions.Visible = $false
    $window.Controls.Add($workdayExceptions)
    $panel.WorkdayExceptions = $workdayExceptions
    $panel.WorkdayExceptionsLabel = $workdayLabel
    $window.Controls.Add($result)
    $panel.Result = $result
    $submit = [Windows.Forms.Button]::new()
    $submit.Text = '计算'
    $submit.SetBounds(306, 191, 88, 34)
    $submit.ForeColor = $window.BackColor
    $submit.BackColor = [Drawing.ColorTranslator]::FromHtml('#F1C56C')
    $submit.FlatStyle = 'Flat'
    $submit.Tag = $panel
    $submit.Add_Click({ param($sender, $eventArgs) Invoke-DateCalculation $sender.Tag })
    $window.Controls.Add($submit)
    $window.AcceptButton = $submit
    $panel.Submit = $submit
    $useResult = [Windows.Forms.Button]::new()
    $useResult.Text = '用作起始'
    $useResult.SetBounds(306, 230, 88, 34)
    $useResult.Enabled = $false
    $useResult.Tag = $panel
    $useResult.Add_Click({
        param($sender, $eventArgs)
        if (!$sender.Enabled) { return }
        $controls = $sender.Tag
        if ($controls.Mode.SelectedItem -eq '星期与周数') {
            $parts = $controls.IsoWeekParts
            $controls.Mode.SelectedItem = '按 ISO 周查日期'
            $controls.Start.Text = $parts[0]
            $controls.Operand.Text = $parts[1]
            $controls.Months.Text = $parts[2]
            [void]$controls.Start.Focus()
            return
        }
        $date = $controls.Result.Text
        if ($controls.Mode.SelectedItem -eq '按 ISO 周查日期') {
            $controls.Mode.SelectedItem = '星期与周数'
        }
        $controls.Start.Text = $date
        $controls.Result.Clear()
        $sender.Enabled = $false
        [void]$controls.Start.Focus()
    })
    $window.Controls.Add($useResult)
    $panel.UseResult = $useResult
    foreach ($operand in @($panel.Start, $panel.Operand, $panel.Months, $panel.Days, $panel.WorkdayExceptions)) {
        $operand.Tag = $panel
        $operand.Add_TextChanged({
            param($sender, $eventArgs)
            $sender.Tag.Result.Clear()
            $sender.Tag.UseResult.Enabled = $false
        })
    }
    $mode.Tag = $panel
    $mode.Add_SelectedIndexChanged({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $combined = $sender.SelectedIndex -in @(7, 8)
        $controls.MonthEnd.Visible = $sender.SelectedIndex -in @(3, 4, 5, 6)
        $workdayMode = $sender.SelectedIndex -in @(10, 11, 12)
        $controls.WorkdayExceptions.Visible = $workdayMode
        $controls.WorkdayExceptionsLabel.Visible = $workdayMode
        $isoLookup = $sender.SelectedIndex -eq 13
        $controls.UseResult.Text = if ($sender.SelectedItem -eq '星期与周数') { '按周反查' } else { '用作起始' }
        $controls.StartCalendar.Visible = !$isoLookup
        if ($isoLookup) {
            $controls.StartDateBeforeIso = $controls.Start.Text
            $controls.StartLabel.Text = 'ISO 周年'
            $controls.OperandLabel.Text = '周数'
            $controls.MonthsLabel.Text = '星期（1 为星期一）'
            $controls.Start.Text = [DateTime]::Today.Year.ToString($invariant)
            $controls.Operand.Text = '1'
            $controls.Months.Text = '1'
            $controls.OperandCalendar.Visible = $false
            $controls.Operand.Width = 182
            $controls.Operand.Visible = $true
            $controls.OperandLabel.Visible = $true
            $controls.Months.Visible = $true
            $controls.MonthsLabel.Visible = $true
            $controls.Days.Visible = $false
            $controls.DaysLabel.Visible = $false
            return
        }
        if ($controls.ContainsKey('StartDateBeforeIso')) {
            $controls.Start.Text = $controls.StartDateBeforeIso
            $controls.StartLabel.Text = '起始日期'
            $controls.Months.Text = '0'
            $controls.Remove('StartDateBeforeIso')
            $controls.MonthsLabel.Text = '月数'
        }
        $useEndDate = $sender.SelectedIndex -in @(0, 10)
        $controls.OperandCalendar.Visible = $useEndDate
        if ($useEndDate) { $controls.Operand.Width = 129 } else { $controls.Operand.Width = 182 }
        $controls.Operand.Visible = $sender.SelectedIndex -ne 9
        $controls.OperandLabel.Visible = $sender.SelectedIndex -ne 9
        foreach ($field in @('Months', 'MonthsLabel', 'Days', 'DaysLabel')) {
            $controls[$field].Visible = $combined
        }
        if ($sender.SelectedIndex -in @(0, 10)) {
            $controls.OperandLabel.Text = '结束日期'
            $controls.Operand.Text = $controls.Start.Text
        } else {
            $controls.OperandLabel.Text = @('', '天数', '天数', '月数', '月数', '年数', '年数', '年数', '年数', '', '', '工作日数', '工作日数', '', '周数', '周数')[$sender.SelectedIndex]
            $controls.Operand.Text = '0'
        }
        $controls.UseResult.Enabled = $false
        $controls.Result.Clear()
    })
    $mode.SelectedIndex = 0
    return $panel
}

$dateButton = New-CalculatorActionButton '日期计算' 16 648 160
$dateButton.Add_Click({
    $panel = New-DateDialog
    try { [void]$panel.Window.ShowDialog($form) }
    finally { $panel.Window.Dispose() }
})

$scientificOperations = [ordered]@{
    '幂运算 xʸ' = @{ Code = 'p9'; FullPrecision = $true; Operand = '底数'; Extra = '指数'; Input = 'Decimal' }
    '阶乘' = @{ Code = 'f'; Operand = '整数'; Exact = $true }
    '正弦 sin' = @{ Code = 's9'; FullPrecision = $true; Operand = '角度'; Extra = '单位'; Input = 'Unit' }
    '余弦 cos' = @{ Code = 'c9'; FullPrecision = $true; Operand = '角度'; Extra = '单位'; Input = 'Unit' }
    '正切 tan' = @{ Code = 't9'; FullPrecision = $true; Operand = '角度'; Extra = '单位'; Input = 'Unit' }
    '自然对数 ln' = @{ Code = 'n9'; FullPrecision = $true; Operand = '正数' }
    '常用对数 log₁₀' = @{ Code = 'l9'; FullPrecision = $true; Operand = '正数' }
    '反正弦 asin' = @{ Code = 'S9'; FullPrecision = $true; Operand = '数值'; Extra = '输出单位'; Input = 'Unit' }
    '反余弦 acos' = @{ Code = 'C9'; FullPrecision = $true; Operand = '数值'; Extra = '输出单位'; Input = 'Unit' }
    '反正切 atan' = @{ Code = 'T9'; FullPrecision = $true; Operand = '数值'; Extra = '输出单位'; Input = 'Unit' }
    '自然指数 eˣ' = @{ Code = 'e9'; FullPrecision = $true; Operand = '指数' }
    '十进制指数 10ˣ' = @{ Code = 'b9'; FullPrecision = $true; Operand = '指数' }
    '整数次方根' = @{ Code = 'g9'; FullPrecision = $true; Operand = '被开方数'; Extra = '根指数'; Input = 'Integer' }
    '任意底数对数' = @{ Code = 'k9'; FullPrecision = $true; Operand = '真数'; Extra = '底数'; Input = 'Decimal' }
    '取余 mod' = @{ Code = '%9'; FullPrecision = $true; Operand = '被除数'; Extra = '除数'; Input = 'Decimal' }
    '倒数 1/x' = @{ Code = 'r9'; FullPrecision = $true; Operand = '非零数' }
    '绝对值 abs' = @{ Code = 'a9'; FullPrecision = $true; Operand = '数值' }
    '向下取整 floor' = @{ Code = 'F'; Operand = '数值' }
    '向上取整 ceil' = @{ Code = 'U'; Operand = '数值' }
    '双曲正弦 sinh' = @{ Code = 'H9'; FullPrecision = $true; Operand = '数值' }
    '双曲余弦 cosh' = @{ Code = 'I9'; FullPrecision = $true; Operand = '数值' }
    '双曲正切 tanh' = @{ Code = 'J9'; FullPrecision = $true; Operand = '数值' }
}

function Invoke-ScientificCalculation($Panel) {
    $Panel.UseResult.Enabled = $false
    $Panel.ToCalculator.Enabled = $false
    $mode = $scientificOperations[[string]$Panel.Mode.SelectedItem]
    $value = $Panel.Value.Text.Trim()
    $extra = $Panel.Exponent.Text.Trim()
    $decimalPattern = '\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z'
    if ($value -notmatch $decimalPattern -or
        ($mode.Input -eq 'Decimal' -and $extra -notmatch $decimalPattern) -or
        ($mode.Input -eq 'Integer' -and $extra -notmatch '\A[0-9]+\z')) {
        $Panel.Result.Text = '请输入有效数值。'
        return
    }
    $arguments = '--science {0} {1}' -f $mode.Code, $value
    if ($mode.Input -eq 'Unit') {
        $arguments += ' ' + @('d', 'r', 'g')[$Panel.Unit.SelectedIndex]
    } elseif ($mode.Input) {
        $arguments += ' ' + $extra
    }
    $response = Invoke-CalculatorCommand $arguments
    $Panel.Result.Text = $response.Text
    if (!$mode.Exact -and $response.Success) {
        $scaled = [long]::Parse($response.Text, $invariant)
        $Panel.Result.Text = if ($mode.FullPrecision) { Format-BaizeInternalValue $scaled } else { Format-BaizeValue $scaled }
    }
    if ($response.Success) {
        $Panel.UseResult.Enabled = $true
        $Panel.LastValue = $Panel.Result.Text
        $Panel.ToCalculator.Enabled = [math]::Abs([decimal]::Parse($Panel.LastValue, $invariant)) -le 2147483647
    }
}

function New-ScientificDialog {
    $window = [Windows.Forms.Form]::new()
    $window.Text = '白泽计算器 · 科学计算'
    $window.ClientSize = [Drawing.Size]::new(410, 240)
    $window.StartPosition = 'CenterParent'
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $window.BackColor = $form.BackColor
    $window.ForeColor = $form.ForeColor
    $window.Font = $form.Font
    $panel = @{ Window = $window }
    $mode = [Windows.Forms.ComboBox]::new()
    $mode.DropDownStyle = 'DropDownList'
    $mode.Items.AddRange([object[]]@($scientificOperations.Keys))
    $mode.SetBounds(16, 16, 378, 32)
    $window.Controls.Add($mode)
    $panel.Mode = $mode
    foreach ($field in @(@{ Key = 'Value'; Label = '底数'; X = 16 }, @{ Key = 'Exponent'; Label = '指数'; X = 212 })) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $field.Label
        $label.SetBounds($field.X, 59, 182, 23)
        $window.Controls.Add($label)
        $inputBox = [Windows.Forms.TextBox]::new()
        $inputBox.MaxLength = 32
        $inputBox.SetBounds($field.X, 84, 182, 31)
        $window.Controls.Add($inputBox)
        $panel[$field.Key] = $inputBox
        $panel[$field.Key + 'Label'] = $label
    }
    $unit = [Windows.Forms.ComboBox]::new()
    $unit.DropDownStyle = 'DropDownList'
    $unit.Items.AddRange([object[]]@('度 (DEG)', '弧度 (RAD)', '百分度 (GRAD)'))
    $unit.SelectedIndex = 0
    $unit.SetBounds(212, 84, 182, 31)
    $window.Controls.Add($unit)
    $panel.Unit = $unit
    $result = [Windows.Forms.TextBox]::new()
    $result.ReadOnly = $true
    $result.SetBounds(16, 137, 280, 32)
    $window.Controls.Add($result)
    $panel.Result = $result
    $submit = [Windows.Forms.Button]::new()
    $submit.Text = '计算'
    $submit.SetBounds(306, 134, 88, 34)
    $submit.ForeColor = $window.BackColor
    $submit.BackColor = [Drawing.ColorTranslator]::FromHtml('#F1C56C')
    $submit.FlatStyle = 'Flat'
    $submit.Tag = $panel
    $submit.Add_Click({ param($sender, $eventArgs) Invoke-ScientificCalculation $sender.Tag })
    $window.Controls.Add($submit)
    $window.AcceptButton = $submit
    $panel.Submit = $submit
    $useResult = [Windows.Forms.Button]::new()
    $useResult.Text = '使用结果'
    $useResult.SetBounds(272, 181, 122, 34)
    $useResult.Enabled = $false
    $useResult.Tag = $panel
    $useResult.Add_Click({
        param($sender, $eventArgs)
        if (!$sender.Enabled) { return }
        $controls = $sender.Tag
        $controls.Value.Text = $controls.Result.Text
        $controls.Result.Clear()
        $controls.UseResult.Enabled = $false
        $sender.Enabled = $false
        [void]$controls.Value.Focus()
    })
    $window.Controls.Add($useResult)
    $panel.UseResult = $useResult
    Add-StandardTransferButton $panel 181
    foreach ($operand in @($panel.Value, $panel.Exponent, $panel.Unit)) { $operand.Tag = $panel }
    $clearResult = {
        param($sender, $eventArgs)
        $sender.Tag.Result.Clear()
        $sender.Tag.UseResult.Enabled = $false
        $sender.Tag.ToCalculator.Enabled = $false
    }
    $panel.Value.Add_TextChanged($clearResult)
    $panel.Exponent.Add_TextChanged($clearResult)
    $panel.Unit.Add_SelectedIndexChanged($clearResult)
    $mode.Tag = $panel
    $mode.Add_SelectedIndexChanged({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $definition = $scientificOperations[[string]$sender.SelectedItem]
        $controls.ValueLabel.Text = $definition.Operand
        $controls.Unit.Visible = $definition.Input -eq 'Unit'
        $controls.Exponent.Visible = $definition.Input -in @('Decimal', 'Integer')
        $controls.ExponentLabel.Text = [string]$definition.Extra
        $controls.Result.Clear()
        $controls.UseResult.Enabled = $false
        $controls.ToCalculator.Enabled = $false
    })
    $mode.SelectedIndex = 0
    if ($state.CanCopy) { $panel.Value.Text = Format-BaizeInternalValue $state.InternalValue }
    return $panel
}

$scientificButton = New-CalculatorActionButton '科学计算' 186 648 160
$scientificButton.Add_Click({
    $panel = New-ScientificDialog
    try { [void]$panel.Window.ShowDialog($form) }
    finally { $panel.Window.Dispose() }
})

$graphColors = @('#F1C56C', '#73D7DD', '#EF9DB7', '#A9D18E')

function Get-GraphRoundedStep([decimal]$Ideal) {
    $magnitude = [decimal][math]::Pow(10, [math]::Floor([math]::Log10([double]$Ideal)))
    foreach ($factor in @(1, 2, 5, 10)) {
        $step = $magnitude * $factor
        if ($step -ge $Ideal) { return $step }
    }
}

function Get-GraphTicks([decimal]$Minimum, [decimal]$Maximum, [int]$Target) {
    $step = Get-GraphRoundedStep (($Maximum - $Minimum) / $Target)
    for ($value = [decimal]::Ceiling($Minimum / $step) * $step; $value -le $Maximum; $value += $step) {
        $value
    }
}

function Get-ClippedGraphSegment([double]$LeftX, [double]$RightX, [double]$LeftY, [double]$RightY, [double]$Middle) {
    if (($LeftY -gt 1 -and $RightY -gt 1) -or ($LeftY -lt -1 -and $RightY -lt -1)) { return }
    $leftBoundary = [math]::Min([double]1, [math]::Max([double]-1, $LeftY))
    $rightBoundary = [math]::Min([double]1, [math]::Max([double]-1, $RightY))
    $deltaY = $RightY - $LeftY
    $deltaX = $RightX - $LeftX
    if ($LeftY -ne $leftBoundary) { $LeftX += $deltaX * (($leftBoundary - $LeftY) / $deltaY) }
    if ($RightY -ne $rightBoundary) { $RightX -= $deltaX * (($RightY - $rightBoundary) / $deltaY) }
    [Drawing.PointF]::new($LeftX, $Middle * (1 - $leftBoundary))
    [Drawing.PointF]::new($RightX, $Middle * (1 - $rightBoundary))
}

function Draw-GraphGrid($Graphics, $Data, [int]$Width, [int]$Height, [Drawing.Font]$Font) {
    $grid = [Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml('#36474D'))
    $labels = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#B4C3C4'))
    try {
        foreach ($value in (Get-GraphTicks $Data.Minimum $Data.Maximum 8)) {
            $x = [single](($value - $Data.Minimum) * $Width / ($Data.Maximum - $Data.Minimum))
            $Graphics.DrawLine($grid, $x, [single]0, $x, [single]$Height)
            $text = $value.ToString('0.##########', $invariant)
            $size = $Graphics.MeasureString($text, $Font)
            $left = [single][math]::Max(0, [math]::Min($Width - $size.Width, $x - $size.Width / 2))
            $Graphics.DrawString($text, $Font, $labels, $left, [single]($Height - $size.Height))
        }
        foreach ($value in (Get-GraphTicks (-$Data.Height) $Data.Height 6)) {
            $y = [single]($Height * (1 - $value / $Data.Height) / 2)
            $Graphics.DrawLine($grid, [single]0, $y, [single]$Width, $y)
            if ($value -eq 0 -or $y -gt $Height - $Font.Height * 2) { continue }
            $text = $value.ToString('0.##########', $invariant)
            $Graphics.DrawString($text, $Font, $labels, [single]3, [single][math]::Max(0, $y - $Font.Height))
        }
    } finally {
        $grid.Dispose()
        $labels.Dispose()
    }
}

function Get-GraphSampleX($Data, [int]$Index) {
    return ($Data.Minimum + $Data.SampleOffsets[$Index] / [decimal]1000000000).ToString('0.#########', $invariant)
}

function Find-GraphSampleIndex($Data, [double]$Fraction) {
    $offsets = $Data.SampleOffsets
    $target = [math]::Max([double]0, [math]::Min([double]1, $Fraction)) * $offsets[$Data.Steps]
    $index = [Array]::BinarySearch($offsets, [long][math]::Floor($target))
    if ($index -lt 0) { $index = [math]::Max(0, (-bnot $index) - 1) }
    if ($index -lt $Data.Steps -and $target - $offsets[$index] -ge $offsets[$index + 1] - $target) {
        $index++
    }
    return $index
}

function Export-CalculatorGraph($Data, [string]$Path) {
    $lines = [Collections.Generic.List[string]]::new()
    $headings = @('x') + @(1..$Data.Series.Count | ForEach-Object { "y$_" })
    $lines.Add(($headings -join ','))
    for ($index = 0; $index -le $Data.Steps; $index++) {
        $fields = @(Get-GraphSampleX $Data $index)
        foreach ($line in $Data.Series) {
            $sample = $line.Samples[$index]
            if ($sample -eq [long]::MaxValue) {
                $fields += ''
            } else {
                $fields += Format-BaizeInternalValue $sample
            }
        }
        $lines.Add(($fields -join ','))
    }
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

function Export-CalculatorGraphImage($Panel, [string]$Path) {
    $canvas = $Panel.Canvas
    $data = $canvas.Tag
    $legendHeight = 26 * $data.Series.Count + 12
    $image = [Drawing.Bitmap]::new($canvas.Width, $canvas.Height + $legendHeight)
    $plot = [Drawing.Bitmap]::new($canvas.Width, $canvas.Height)
    $graphics = [Drawing.Graphics]::FromImage($image)
    $format = [Drawing.StringFormat]::new()
    $format.Trimming = 'EllipsisCharacter'
    $format.FormatFlags = 'NoWrap'
    $cursor = $data.Cursor
    try {
        $data.Cursor = -1
        $canvas.DrawToBitmap($plot, $canvas.ClientRectangle)
        $graphics.Clear($canvas.BackColor)
        for ($index = 0; $index -lt $data.Series.Count; $index++) {
            $series = $data.Series[$index]
            $brush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($series.Color))
            try {
                $legendBounds = [Drawing.RectangleF]::new(12, (6 + 26 * $index), ($image.Width - 24), 24)
                $graphics.DrawString($series.Expression, $Panel.Window.Font, $brush, $legendBounds, $format)
            } finally { $brush.Dispose() }
        }
        $graphics.DrawImageUnscaled($plot, 0, $legendHeight)
        $image.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $data.Cursor = $cursor
        $format.Dispose()
        $graphics.Dispose()
        $plot.Dispose()
        $image.Dispose()
    }
}

function Clear-CalculatorGraph($Panel) {
    if ($Panel.FirstCurve.SelectedIndex -ge 0 -and $Panel.SecondCurve.SelectedIndex -ge 0) {
        $Panel.PreviousCurves = @($Panel.FirstCurve.SelectedIndex, $Panel.SecondCurve.SelectedIndex)
    }
    $Panel.CopyIntersections.Enabled = $false
    $Panel.Canvas.Tag = $null
    $Panel.Export.Enabled = $false
    $Panel.Fit.Enabled = $false
    $Panel.Evaluate.Enabled = $false
    Clear-GraphPointResult $Panel
    $Panel.Roots.Enabled = $false
    $Panel.Intersections.Enabled = $false
    $Panel.FirstCurve.Items.Clear()
    $Panel.SecondCurve.Items.Clear()
    $Panel.Readout.Clear()
    $Panel.Canvas.Invalidate()
    foreach ($label in $Panel.Legend) { $label.Text = '' }
}

function Invoke-CalculatorGraph($Panel) {
    Clear-CalculatorGraph $Panel
    $rawExpressions = $Panel.Expression.Text.Split(';')
    $expressions = @($rawExpressions | ForEach-Object { $_.Trim() })
    if ($expressions.Count -gt $graphColors.Count) {
        $Panel.Status.Text = '最多绘制四条曲线，请用分号分隔表达式。'
        return
    }
    $minimum = $Panel.Minimum.Text.Trim()
    $maximum = $Panel.Maximum.Text.Trim()
    $decimalPattern = '\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z'
    $height = Get-CalculatorGraphHeight $Panel.Height.Text
    if ($minimum -notmatch $decimalPattern -or $maximum -notmatch $decimalPattern -or $null -eq $height) {
        $Panel.Status.Text = '请检查坐标范围。纵轴上限须在 0.000000001 到 2147483647 之间。'
        return
    }
    $sampleCount = [int]$Panel.Density.SelectedItem
    $series = @()
    $withoutPoints = 0
    $expressionOffset = 0
    foreach ($expression in $expressions) {
        $number = $series.Count + 1
        if ($expression -notmatch '\A[0-9a-zE+*/^(). \t-]+\z') {
            $Panel.Status.Text = "第 $number 条表达式为空或含有无效字符。"
            return
        }
        $response = Invoke-CalculatorCommand ('--graph9 "{0}" {1} {2} s {3}' -f $expression, $minimum, $maximum, $sampleCount)
        $lines = $response.Text -split '\r?\n'
        if (!$response.Success) {
            $offset = 0
            if ($lines.Count -eq 2 -and [int]::TryParse($lines[1], [ref]$offset)) {
                $raw = $rawExpressions[$number - 1]
                $leading = $raw.Length - $raw.TrimStart().Length
                $position = $expressionOffset + $leading + $offset
                $length = [int]($offset -lt $expression.Length)
                [void]$Panel.Expression.Focus()
                $Panel.Expression.Select($position, $length)
                $Panel.Status.Text = "第 $number 条 · 第 $($offset + 1) 个字符附近有语法错误"
            } else {
                $Panel.Status.Text = "第 $number 条 · $($lines[-1])"
            }
            return
        }
        if ($lines.Count -ne 2 * $sampleCount) { throw '绘图程序返回的采样数量错误' }
        $samples = [long[]]::new($sampleCount)
        $links = [bool[]]::new($sampleCount)
        for ($index = 0; $index -lt $sampleCount; $index++) {
            $samples[$index] = [long]::Parse($lines[2 * $index], $invariant)
            $links[$index] = $lines[2 * $index + 1] -eq '1'
        }
        if (@($samples | Where-Object { $_ -ne [long]::MaxValue }).Count -eq 0) { $withoutPoints++ }
        $series += @{ Samples = $samples; Links = $links; Color = $graphColors[$number - 1]; Expression = $expression }
        $expressionOffset += $rawExpressions[$number - 1].Length + 1
    }
    for ($index = 0; $index -lt $expressions.Count; $index++) {
        $Panel.Legend[$index].Text = $expressions[$index]
    }
    $minimumValue = [decimal]::Parse($minimum, $invariant)
    $maximumValue = [decimal]::Parse($maximum, $invariant)
    $span = ($maximumValue - $minimumValue) * 1000000000
    $steps = $sampleCount - 1
    # Match the worker's truncation of the positive offset at each sample.
    $offsets = [long[]]::new($sampleCount)
    for ($index = 0; $index -le $steps; $index++) {
        $offsets[$index] = [long][decimal]::Floor($span * $index / $steps)
    }
    $Panel.Canvas.Tag = @{
        Series = $series
        Steps = $steps
        SampleOffsets = $offsets
        Markers = @()
        IntersectionReadout = $null
        WithoutPoints = $withoutPoints
        Minimum = $minimumValue
        Maximum = $maximumValue
        Height = $height
        Cursor = -1
        Readout = $Panel.Readout
    }
    $Panel.Canvas.Invalidate()
    $Panel.Export.Enabled = $true
    $Panel.Fit.Enabled = $withoutPoints -lt $series.Count
    $Panel.Evaluate.Enabled = $true
    $Panel.Roots.Enabled = $true
    if ($series.Count -ge 2) {
        $choices = [object[]]@(1..$series.Count | ForEach-Object { "y$_" })
        $Panel.FirstCurve.Items.AddRange($choices)
        $Panel.SecondCurve.Items.AddRange($choices)
        $Panel.FirstCurve.SelectedIndex = 0
        $Panel.SecondCurve.SelectedIndex = 1
        if ($null -ne $Panel.PreviousCurves -and $Panel.PreviousCurves[0] -lt $choices.Count -and
            $Panel.PreviousCurves[1] -lt $choices.Count) {
            $Panel.FirstCurve.SelectedIndex = $Panel.PreviousCurves[0]
            $Panel.SecondCurve.SelectedIndex = $Panel.PreviousCurves[1]
        }
        $Panel.Intersections.Enabled = $true
    }
    Update-GraphStatus $Panel
}

function Update-GraphStatus($Panel) {
    $data = $Panel.Canvas.Tag
    $Panel.Status.Text = "$($data.Series.Count) 条曲线 · $($data.Steps + 1) 点 · 纵轴 ±$($data.Height.ToString('0.##########', $invariant))"
    if ($data.WithoutPoints -gt 0) { $Panel.Status.Text += " · $($data.WithoutPoints) 条无有效采样" }
}

function Get-CalculatorGraphHeight([string]$Text) {
    $height = [decimal]0
    if ($Text.Trim() -match '\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z' -and
        [decimal]::TryParse($Text, [Globalization.NumberStyles]::Float, $invariant, [ref]$height) -and
        $height -ge 0.000000001D -and $height -le 2147483647) {
        return $height
    }
}

function Fit-CalculatorGraphHeight($Panel) {
    $data = $Panel.Canvas.Tag
    if ($null -eq $data -or $data.WithoutPoints -eq $data.Series.Count) { return }
    $peak = 0L
    foreach ($line in $data.Series) {
        foreach ($sample in $line.Samples) {
            if ($sample -eq [long]::MaxValue) { continue }
            $peak = [math]::Max($peak, [math]::Abs($sample))
        }
    }
    $height = 1d
    if ($peak -ne 0) {
        $height = [math]::Min(2147483647d, (Get-GraphRoundedStep ([decimal]$peak / 1000000000 * 1.05d)))
    }
    $data.Height = $height
    $Panel.Height.Text = $height.ToString('0.#########', $invariant)
    $Panel.Canvas.Invalidate()
    Update-GraphStatus $Panel
}

function Clear-GraphPointResult($Panel) {
    $Panel.ToCalculator.Enabled = $false
    $Panel.PointResult.Items.Clear()
}

function Invoke-GraphPoint($Panel) {
    Clear-GraphPointResult $Panel
    if (!$Panel.Evaluate.Enabled) { return }
    $data = $Panel.Canvas.Tag
    if ($null -eq $data) { return }
    $x = $Panel.PointX.Text.Trim()
    if ($x -notmatch '\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z') {
        $Panel.Readout.Text = '请输入有效横坐标。'
        return
    }
    $columns = @("x = $x")
    $choices = @()
    $values = @()
    for ($index = 0; $index -lt $data.Series.Count; $index++) {
        $response = Invoke-CalculatorCommand ('--graph9 "{0}" {1}' -f $data.Series[$index].Expression, $x)
        if (!$response.Success) { $Panel.Readout.Text = $response.Text; return }
        $sample = [long]::Parse($response.Text, $invariant)
        $value = '无值'
        if ($sample -ne [long]::MaxValue) {
            $value = Format-BaizeInternalValue $sample
            $choices += "y$($index + 1) = $value"
            $values += $value
        }
        $columns += "y$($index + 1) = $value"
    }
    if ($choices.Count -gt 0) {
        $Panel.PointValues = $values
        $Panel.PointResult.Items.AddRange([object[]]$choices)
        $Panel.PointResult.SelectedIndex = 0
    }
    $data.Cursor = -1
    $Panel.Canvas.Invalidate()
    $Panel.Readout.Text = $columns -join '    '
}

function Get-GraphRoots($Data, [string]$Expression) {
    $minimum = $Data.Minimum.ToString($invariant)
    $maximum = $Data.Maximum.ToString($invariant)
    $response = Invoke-CalculatorCommand ('--graph "{0}" {1} {2} z {3}' -f $Expression, $minimum, $maximum, ($Data.Steps + 1))
    $response.Coordinates = @()
    if ($response.Success) {
        if ($response.Text -eq '') {
            $response.Text = '未找到'
        } else {
            $response.Coordinates = @($response.Text -split '\r?\n' | ForEach-Object {
                [decimal]::Parse($_, $invariant) / 1000000000
            })
            $response.Text = ($response.Coordinates | ForEach-Object { $_.ToString('0.#########', $invariant) }) -join ', '
        }
    }
    return $response
}

function Find-CalculatorGraphRoots($Panel) {
    $Panel.CopyIntersections.Enabled = $false
    $data = $Panel.Canvas.Tag
    if ($null -eq $data) { return }
    $markers = @()
    $groups = @()
    for ($index = 0; $index -lt $data.Series.Count; $index++) {
        $response = Get-GraphRoots $data $data.Series[$index].Expression
        if (!$response.Success) { $Panel.Readout.Text = $response.Text; return }
        $groups += "y$($index + 1)：$($response.Text)"
        foreach ($coordinate in $response.Coordinates) {
            $markers += @{ X = $coordinate; Y = 0; Color = $data.Series[$index].Color }
        }
    }
    $Panel.Readout.Text = $groups -join '    '
    $data.IntersectionReadout = $null
    $data.Markers = $markers
    $Panel.Canvas.Invalidate()
}

function Find-CalculatorGraphIntersections($Panel) {
    $Panel.CopyIntersections.Enabled = $false
    $Panel.CopyIntersections.Text = '复制交点'
    $data = $Panel.Canvas.Tag
    if ($null -eq $data) { return }
    $data.IntersectionReadout = $null
    $data.Markers = @()
    $Panel.Canvas.Invalidate()
    $first = $Panel.FirstCurve.SelectedIndex
    $second = $Panel.SecondCurve.SelectedIndex
    if ($first -eq $second) {
        $Panel.Readout.Text = '请选择两条不同的曲线。'
        return
    }
    $left = $data.Series[$first].Expression
    $right = $data.Series[$second].Expression
    if ($left -ceq $right) {
        $Panel.Readout.Text = '两个表达式相同，曲线重合。'
        return
    }
    $leftSamples = $data.Series[$first].Samples
    $rightSamples = $data.Series[$second].Samples
    $matchingPoints = 0
    for ($index = 0; $index -lt $leftSamples.Count; $index++) {
        if ($leftSamples[$index] -ne $rightSamples[$index]) { break }
        if ($leftSamples[$index] -ne [long]::MaxValue) { $matchingPoints++ }
    }
    if ($index -eq $leftSamples.Count -and $matchingPoints -ge 2) {
        $Panel.Readout.Text = '两条曲线在当前采样点上重合。'
        return
    }
    $difference = "($left)-($right)"
    if ($difference.Length -gt 1024) {
        $Panel.Readout.Text = '两条表达式合并后超过 1024 字符，请缩短后重试。'
        return
    }
    $response = Get-GraphRoots $data $difference
    if (!$response.Success) { $Panel.Readout.Text = $response.Text; return }
    $markers = @()
    $pairs = @()
    foreach ($coordinate in $response.Coordinates) {
        $x = $coordinate.ToString('0.#########', $invariant)
        $point = Invoke-CalculatorCommand ('--graph9 "{0}" {1}' -f $left, $x)
        if (!$point.Success) { $Panel.Readout.Text = $point.Text; return }
        $sample = [long]::Parse($point.Text, $invariant)
        if ($sample -eq [long]::MaxValue) { continue }
        $y = Format-BaizeInternalValue $sample
        $pairs += "($x, $y)"
        $markers += @{ X = $coordinate; Y = [decimal]$sample / 1000000000; Color = '#FAF4E7' }
    }
    $coordinates = '未找到'
    if ($pairs.Count -gt 0) {
        $coordinates = $pairs -join ', '
        $Panel.CopyIntersections.Tag = $pairs -join [Environment]::NewLine
        $Panel.CopyIntersections.Enabled = $true
    }
    $Panel.Readout.Text = "y$($first + 1) 与 y$($second + 1) 的交点：$coordinates"
    $data.IntersectionReadout = $Panel.Readout.Text
    $data.Markers = $markers
    $Panel.Canvas.Invalidate()
}

function Set-CalculatorGraphRange($Panel, [decimal]$Minimum, [decimal]$Span) {
    $left = [math]::Max(-1000d, [math]::Min(1000d - $Span, $Minimum))
    $Panel.Minimum.Text = $left.ToString('0.#########', $invariant)
    $Panel.Maximum.Text = ($left + $Span).ToString('0.#########', $invariant)
    Invoke-CalculatorGraph $Panel
}

function Zoom-CalculatorGraph($Panel, [decimal]$Factor) {
    $data = $Panel.Canvas.Tag
    if ($null -eq $data) { return }
    $position = 0.5d
    if ($data.Cursor -ge 0) { $position = [decimal]$data.Cursor / $data.Steps }
    $span = $data.Maximum - $data.Minimum
    $center = $data.Minimum + $span * $position
    $minimumSpan = ([decimal][int]$Panel.Density.SelectedItem - 1) / 1000000000
    $newSpan = [math]::Min(2000d, [math]::Max($minimumSpan, $span * $Factor))
    Set-CalculatorGraphRange $Panel ($center - $newSpan * $position) $newSpan
    if ($null -ne $Panel.Canvas.Tag -and $data.Cursor -ge 0) {
        $Panel.Canvas.Tag.Cursor = [int][math]::Round($position * $Panel.Canvas.Tag.Steps)
    }
}

function Show-GraphSample($Canvas, [int]$index) {
    $data = $Canvas.Tag
    $data.Cursor = $index
    $x = Get-GraphSampleX $data $index
    $columns = @("x = $x")
    for ($lineIndex = 0; $lineIndex -lt $data.Series.Count; $lineIndex++) {
        $sample = $data.Series[$lineIndex].Samples[$index]
        $value = '无值'
        if ($sample -ne [long]::MaxValue) { $value = Format-BaizeInternalValue $sample }
        $columns += "y$($lineIndex + 1) = $value"
    }
    $data.Readout.Text = $columns -join '    '
    $Canvas.Invalidate()
}

function New-GraphDialog {
    $window = [Windows.Forms.Form]::new()
    $window.Text = '白泽计算器 · 绘图'
    $window.ClientSize = [Drawing.Size]::new(660, 636)
    $window.StartPosition = 'CenterParent'
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $window.BackColor = $form.BackColor
    $window.ForeColor = $form.ForeColor
    $window.Font = $form.Font
    $panel = @{ Window = $window }
    foreach ($field in @(
        @{ Key = 'Expression'; Title = 'y =（分号分隔）'; Text = 'x^2'; X = 16; Width = 230; Limit = 1024 },
        @{ Key = 'Minimum'; Title = '最小 x'; Text = '-10'; X = 254; Width = 86; Limit = 24 },
        @{ Key = 'Maximum'; Title = '最大 x'; Text = '10'; X = 348; Width = 86; Limit = 24 },
        @{ Key = 'Height'; Title = '纵轴上限'; Text = '10'; X = 442; Width = 106; Limit = 24 }
    )) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $field.Title
        $label.SetBounds($field.X, 12, $field.Width, 23)
        $window.Controls.Add($label)
        $box = [Windows.Forms.TextBox]::new()
        $box.Text = $field.Text
        $box.MaxLength = $field.Limit
        $box.AccessibleName = $field.Title
        $box.SetBounds($field.X, 36, $field.Width, 29)
        $window.Controls.Add($box)
        $panel[$field.Key] = $box
    }
    $canvas = [Windows.Forms.Panel]::new()
    $canvas.SetBounds(16, 104, 628, 328)
    $canvas.BackColor = [Drawing.ColorTranslator]::FromHtml('#243138')
    $canvas.AccessibleName = '函数曲线'
    $tickFont = [Drawing.Font]::new($window.Font.FontFamily, 9)
    $canvas.Font = $tickFont
    $canvas.Add_Disposed({ param($sender, $eventArgs) $sender.Font.Dispose() })
    $canvas.Add_MouseDown({
        param($sender, $eventArgs)
        $data = $sender.Tag
        if ($null -eq $data -or $eventArgs.Button -ne 'Left') { return }
        $data.DragStartX = $eventArgs.X
        $data.Cursor = -1
        $data.Readout.Text = '松开鼠标以平移横轴'
        $sender.Cursor = [Windows.Forms.Cursors]::SizeWE
        if (!$Verify) { $sender.Capture = $true }
        $sender.Invalidate()
    })
    $canvas.Add_MouseUp({
        param($sender, $eventArgs)
        $data = $sender.Tag
        if ($null -eq $data -or $null -eq $data.DragStartX -or $eventArgs.Button -ne 'Left') { return }
        $delta = $data.DragStartX - $eventArgs.X
        $data.DragStartX = $null
        if (!$Verify) { $sender.Capture = $false }
        $sender.Cursor = [Windows.Forms.Cursors]::Default
        $data.Readout.Clear()
        if ($delta -eq 0) { return }
        $span = $data.Maximum - $data.Minimum
        $width = [math]::Max(1, $sender.ClientSize.Width - 1)
        $shift = $span * $delta / $width
        Set-CalculatorGraphRange $sender.Parent.Tag ($data.Minimum + $shift) $span
    })
    $canvas.Add_MouseCaptureChanged({
        param($sender, $eventArgs)
        if ($sender.Capture -or $null -eq $sender.Tag -or $null -eq $sender.Tag.DragStartX) { return }
        $sender.Tag.DragStartX = $null
        $sender.Tag.Readout.Clear()
        $sender.Cursor = [Windows.Forms.Cursors]::Default
        $sender.Invalidate()
    })
    $canvas.Add_MouseMove({
        param($sender, $eventArgs)
        $data = $sender.Tag
        if ($null -eq $data -or $null -ne $data.DragStartX) { return }
        $width = [math]::Max(1, $sender.ClientSize.Width - 1)
        $index = Find-GraphSampleIndex $data ($eventArgs.X / [double]$width)
        if ($index -eq $data.Cursor -and $data.Readout.Text -ne '') { return }
        Show-GraphSample $sender $index
    })
    $canvas.Add_MouseLeave({
        param($sender, $eventArgs)
        if ($null -eq $sender.Tag) { return }
        $sender.Tag.Cursor = -1
        $sender.Tag.Readout.Clear()
        $sender.Invalidate()
    })
    $canvas.Add_Paint({
        param($sender, $eventArgs)
        $data = $sender.Tag
        if ($null -eq $data) { return }
        $g = $eventArgs.Graphics
        $width = $sender.ClientSize.Width - 1
        $height = $sender.ClientSize.Height - 1
        $g.SmoothingMode = 'AntiAlias'
        $axis = [Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml('#84979C'))
        try {
            Draw-GraphGrid $g $data $width $height $sender.Font
            $middle = $height / 2
            $g.DrawLine($axis, [single]0, [single]$middle, [single]$width, [single]$middle)
            if ($data.Minimum -le 0 -and $data.Maximum -ge 0) {
                $zero = -$data.Minimum * $width / ($data.Maximum - $data.Minimum)
                $g.DrawLine($axis, [single]$zero, [single]0, [single]$zero, [single]$height)
            }
            $pixelsPerTick = $width / [double]$data.SampleOffsets[$data.Steps]
            if ($data.Cursor -ge 0) {
                $cursorX = $data.SampleOffsets[$data.Cursor] * $pixelsPerTick
                $axis.DashStyle = 'Dot'
                $g.DrawLine($axis, [single]$cursorX, [single]0, [single]$cursorX, [single]$height)
            }
            foreach ($line in $data.Series) {
                $curve = [Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml($line.Color), 2)
                try {
                    $previous = $null
                    for ($index = 0; $index -lt $line.Samples.Count; $index++) {
                        $sample = $line.Samples[$index]
                        if ($sample -eq [long]::MaxValue) { $previous = $null; continue }
                        $fraction = $sample / 1000000000.0 / $data.Height
                        if ($line.Links[$index]) {
                            $leftX = $data.SampleOffsets[$index - 1] * $pixelsPerTick
                            $rightX = $data.SampleOffsets[$index] * $pixelsPerTick
                            if ([math]::Abs($previous) -le 1 -and [math]::Abs($fraction) -le 1) {
                                $g.DrawLine($curve, [single]$leftX, [single]($middle * (1 - $previous)),
                                    [single]$rightX, [single]($middle * (1 - $fraction)))
                            } else {
                                $segment = Get-ClippedGraphSegment $leftX $rightX $previous $fraction $middle
                                if ($null -ne $segment) { $g.DrawLine($curve, $segment[0], $segment[1]) }
                            }
                        }
                        $previous = $fraction
                    }
                } finally { $curve.Dispose() }
            }
            foreach ($marker in $data.Markers) {
                if ($marker.X -lt $data.Minimum -or $marker.X -gt $data.Maximum -or
                    [math]::Abs($marker.Y) -gt $data.Height) { continue }
                $x = [single](($marker.X - $data.Minimum) * $width / ($data.Maximum - $data.Minimum))
                $y = [single]($middle * (1 - $marker.Y / $data.Height))
                $markerBrush = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($marker.Color))
                try { $g.FillEllipse($markerBrush, [single]($x - 4), [single]($y - 4), [single]8, [single]8) }
                finally { $markerBrush.Dispose() }
            }
        } finally {
            $axis.Dispose()
        }
    })
    $window.Controls.Add($canvas)
    $panel.Canvas = $canvas
    $panel.Legend = @(
        for ($index = 0; $index -lt $graphColors.Count; $index++) {
            $legend = [Windows.Forms.Label]::new()
            $legend.ForeColor = [Drawing.ColorTranslator]::FromHtml($graphColors[$index])
            $legend.SetBounds((16 + $index * 157), 76, 151, 24)
            $legend.AutoEllipsis = $true
            $window.Controls.Add($legend)
            $legend
        }
    )
    $status = [Windows.Forms.Label]::new()
    $status.SetBounds(16, 441, 507, 33)
    $window.Controls.Add($status)
    $panel.Status = $status
    $readout = [Windows.Forms.TextBox]::new()
    $readout.ReadOnly = $true
    $readout.AccessibleName = '绘图采样坐标'
    $readout.SetBounds(16, 473, 628, 29)
    $window.Controls.Add($readout)
    $panel.Readout = $readout
    $readout.Tag = $panel
    $readout.AccessibleDescription = '按向左或向右方向键逐点查看采样'
    $readout.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        $data = $sender.Tag.Canvas.Tag
        if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Enter -and $null -ne $data -and $data.Cursor -ge 0) {
            $eventArgs.IsInputKey = $true
        }
    })
    $readout.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Modifiers -ne [Windows.Forms.Keys]::None) { return }
        $data = $sender.Tag.Canvas.Tag
        if ($null -eq $data) { return }
        if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Enter -and $data.Cursor -ge 0) {
            $sender.Tag.PointX.Text = Get-GraphSampleX $data $data.Cursor
            Invoke-GraphPoint $sender.Tag
            $eventArgs.SuppressKeyPress = $true
            return
        }
        $direction = switch ($eventArgs.KeyCode) {
            'Left' { -1 }
            'Right' { 1 }
        }
        if ($null -eq $direction) { return }
        $index = $data.Cursor + $direction
        if ($data.Cursor -lt 0 -and $direction -lt 0) { $index = $data.Steps }
        $index = [math]::Max(0, [math]::Min($data.Steps, $index))
        Show-GraphSample $sender.Tag.Canvas $index
        $eventArgs.SuppressKeyPress = $true
    })
    $fit = [Windows.Forms.Button]::new()
    $fit.Text = '适配纵轴'
    $fit.SetBounds(532, 438, 112, 31)
    $fit.Enabled = $false
    $fit.Tag = $panel
    $fit.Add_Click({ param($sender, $eventArgs) Fit-CalculatorGraphHeight $sender.Tag })
    $window.Controls.Add($fit)
    $panel.Fit = $fit
    $draw = [Windows.Forms.Button]::new()
    $draw.Text = '绘制'
    $draw.SetBounds(555, 34, 89, 34)
    $draw.ForeColor = $window.BackColor
    $draw.BackColor = [Drawing.ColorTranslator]::FromHtml('#F1C56C')
    $draw.FlatStyle = 'Flat'
    $draw.Tag = $panel
    $draw.Add_Click({ param($sender, $eventArgs) Invoke-CalculatorGraph $sender.Tag })
    $window.Controls.Add($draw)
    $window.AcceptButton = $draw
    $panel.Draw = $draw
    foreach ($option in @(
        @{ Caption = '放大'; X = 16; Factor = 0.5d; Key = 'ZoomIn' },
        @{ Caption = '缩小'; X = 108; Factor = 2d; Key = 'ZoomOut' },
        @{ Caption = '重置坐标'; X = 200; Key = 'Reset' }
    )) {
        $button = [Windows.Forms.Button]::new()
        $button.Text = $option.Caption
        $button.SetBounds($option.X, 509, 86, 31)
        $button.Tag = @{ Panel = $panel; Factor = $option.Factor }
        $button.Add_Click({
            param($sender, $eventArgs)
            $action = $sender.Tag
            if ($action.Factor) {
                Zoom-CalculatorGraph $action.Panel $action.Factor
            } else {
                $action.Panel.Minimum.Text = '-10'
                $action.Panel.Maximum.Text = '10'
                $action.Panel.Height.Text = '10'
                Invoke-CalculatorGraph $action.Panel
            }
        })
        $window.Controls.Add($button)
        $panel[$option.Key] = $button
    }
    $export = [Windows.Forms.Button]::new()
    $export.Text = '导出'
    $export.SetBounds(292, 509, 104, 31)
    $export.Enabled = $false
    $export.Tag = $panel
    $export.Add_Click({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $data = $controls.Canvas.Tag
        if ($null -eq $data) { return }
        $dialog = [Windows.Forms.SaveFileDialog]::new()
        $dialog.Filter = 'CSV 采样数据 (*.csv)|*.csv|PNG 图像 (*.png)|*.png'
        $dialog.FileName = '白泽绘图'
        try {
            if ($dialog.ShowDialog($controls.Window) -eq 'OK') {
                try {
                    if ($dialog.FilterIndex -eq 2) {
                        Export-CalculatorGraphImage $controls $dialog.FileName
                        $controls.Status.Text = '已导出当前曲线的 PNG 图像。'
                    } else {
                        Export-CalculatorGraph $data $dialog.FileName
                        $controls.Status.Text = '已导出当前曲线的采样点。'
                    }
                } catch {
                    $controls.Status.Text = '无法写入导出文件，请检查保存位置。'
                }
            }
        } finally { $dialog.Dispose() }
    })
    $window.Controls.Add($export)
    $panel.Export = $export
    $pointX = [Windows.Forms.TextBox]::new()
    $pointX.SetBounds(415, 510, 137, 29)
    $pointX.AccessibleName = '单点求值横坐标'
    $pointX.MaxLength = 32
    $pointX.Text = '0'
    $window.Controls.Add($pointX)
    $panel.PointX = $pointX
    $evaluate = [Windows.Forms.Button]::new()
    $evaluate.Text = '求点值'
    $evaluate.SetBounds(558, 509, 86, 31)
    $evaluate.Enabled = $false
    $evaluate.Tag = $panel
    $evaluate.Add_Click({ param($sender, $eventArgs) Invoke-GraphPoint $sender.Tag })
    $window.Controls.Add($evaluate)
    $panel.Evaluate = $evaluate
    $densityLabel = [Windows.Forms.Label]::new()
    $densityLabel.Text = '采样点数'
    $densityLabel.SetBounds(16, 555, 88, 26)
    $window.Controls.Add($densityLabel)
    $density = [Windows.Forms.ComboBox]::new()
    $density.DropDownStyle = 'DropDownList'
    $density.AccessibleName = '采样点数'
    $density.Items.AddRange([object[]]@('201', '401', '801'))
    $density.SelectedIndex = 0
    $density.SetBounds(108, 550, 96, 30)
    $window.Controls.Add($density)
    $panel.Density = $density
    $roots = [Windows.Forms.Button]::new()
    $roots.Text = '查找零点'
    $roots.SetBounds(215, 550, 104, 30)
    $roots.Enabled = $false
    $roots.Tag = $panel
    $roots.Add_Click({ param($sender, $eventArgs) Find-CalculatorGraphRoots $sender.Tag })
    $window.Controls.Add($roots)
    $panel.Roots = $roots
    foreach ($choice in @(@{ Key = 'FirstCurve'; X = 334; Label = '第一条曲线' }, @{ Key = 'SecondCurve'; X = 407; Label = '第二条曲线' })) {
        $selector = [Windows.Forms.ComboBox]::new()
        $selector.DropDownStyle = 'DropDownList'
        $selector.AccessibleName = $choice.Label
        $selector.Tag = $panel
        $selector.Add_SelectedIndexChanged({
            param($sender, $eventArgs)
            $controls = $sender.Tag
            $controls.CopyIntersections.Enabled = $false
            $controls.CopyIntersections.Text = '复制交点'
            $data = $controls.Canvas.Tag
            if ($null -ne $data -and $null -ne $data.IntersectionReadout) {
                if ($controls.Readout.Text -ceq $data.IntersectionReadout) { $controls.Readout.Clear() }
                $data.IntersectionReadout = $null
                $data.Markers = @()
                $controls.Canvas.Invalidate()
            }
        })
        $selector.SetBounds($choice.X, 550, 66, 30)
        $window.Controls.Add($selector)
        $panel[$choice.Key] = $selector
    }
    $intersections = [Windows.Forms.Button]::new()
    $intersections.Text = '查找交点'
    $intersections.SetBounds(482, 550, 113, 30)
    $intersections.Enabled = $false
    $intersections.Tag = $panel
    $intersections.Add_Click({ param($sender, $eventArgs) Find-CalculatorGraphIntersections $sender.Tag })
    $window.Controls.Add($intersections)
    $panel.Intersections = $intersections
    Add-StandardTransferButton $panel 594
    $pointResult = [Windows.Forms.ComboBox]::new()
    $pointResult.DropDownStyle = 'DropDownList'
    $pointResult.AccessibleName = '要带回标准模式的纵坐标'
    $pointResult.SetBounds(194, 594, 286, 30)
    $pointResult.Tag = $panel
    $pointResult.Add_SelectedIndexChanged({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $controls.ToCalculator.Enabled = $sender.SelectedIndex -ge 0
        if ($controls.ToCalculator.Enabled) { $controls.LastValue = $controls.PointValues[$sender.SelectedIndex] }
    })
    $window.Controls.Add($pointResult)
    $panel.PointResult = $pointResult
    $copyIntersections = [Windows.Forms.Button]::new()
    $copyIntersections.Text = '复制交点'
    $copyIntersections.SetBounds(492, 594, 112, 30)
    $copyIntersections.Enabled = $false
    $copyIntersections.Add_Click({
        param($sender, $eventArgs)
        if (!$sender.Enabled) { return }
        try {
            & $copyToClipboard $sender.Tag
            $sender.Text = '已复制'
        } catch [Runtime.InteropServices.ExternalException] {
            $sender.Text = '复制失败，重试'
        }
    })
    $window.Controls.Add($copyIntersections)
    $panel.CopyIntersections = $copyIntersections
    $pointX.Tag = $panel
    $pointX.Add_Enter({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $controls.Window.AcceptButton = $controls.Evaluate
    })
    $pointX.Add_Leave({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $controls.Window.AcceptButton = $controls.Draw
    })
    $pointX.Add_TextChanged({ param($sender, $eventArgs) Clear-GraphPointResult $sender.Tag })
    $panel.Expression.Tag = $panel
    $panel.Expression.Add_TextChanged({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        Clear-CalculatorGraph $controls
        $controls.PreviousCurves = $null
        $controls.Status.Text = '表达式已更改，请重新绘制。'
    })
    $panel.Height.Tag = $panel
    $panel.Height.AccessibleDescription = '输入纵轴上限后按回车应用'
    $panel.Height.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.KeyCode -eq [Windows.Forms.Keys]::Enter -and $null -ne $sender.Tag.Canvas.Tag) {
            $eventArgs.IsInputKey = $true
        }
    })
    $panel.Height.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.KeyCode -ne [Windows.Forms.Keys]::Enter) { return }
        $controls = $sender.Tag
        $data = $controls.Canvas.Tag
        if ($null -eq $data) { return }
        $eventArgs.SuppressKeyPress = $true
        $height = Get-CalculatorGraphHeight $sender.Text
        if ($null -eq $height) {
            $controls.Status.Text = '纵轴上限须在 0.000000001 到 2147483647 之间。'
            return
        }
        $data.Height = $height
        $controls.Canvas.Invalidate()
        Update-GraphStatus $controls
    })
    $samplingChanged = {
        param($sender, $eventArgs)
        $controls = $sender.Tag
        Clear-CalculatorGraph $controls
        $controls.Status.Text = '采样范围或密度已更改，请重新绘制。'
    }
    $panel.Minimum.Tag = $panel
    $panel.Maximum.Tag = $panel
    $panel.Density.Tag = $panel
    $panel.Minimum.Add_TextChanged($samplingChanged)
    $panel.Maximum.Add_TextChanged($samplingChanged)
    $panel.Density.Add_SelectedIndexChanged($samplingChanged)
    $window.Tag = $panel
    $window.Add_MouseWheel({
        param($sender, $eventArgs)
        $controls = $sender.Tag
        if ($null -eq $controls.Canvas.Tag -or $controls.Canvas.Tag.Cursor -lt 0) { return }
        if ($eventArgs.Delta -gt 0) { Zoom-CalculatorGraph $controls 0.5d }
        if ($eventArgs.Delta -lt 0) { Zoom-CalculatorGraph $controls 2d }
    })
    return $panel
}

$graphButton = New-CalculatorActionButton '绘图' 16 687 160
$graphButton.Add_Click({
    $panel = New-GraphDialog
    try {
        Invoke-CalculatorGraph $panel
        [void]$panel.Window.ShowDialog($form)
    } finally { $panel.Window.Dispose() }
})

function New-CalculatorExpressionDialog([string]$InitialExpression = '') {
    $window = [Windows.Forms.Form]::new()
    $window.Text = '白泽计算器 · 输入算式'
    $window.ClientSize = [Drawing.Size]::new(548, 145)
    $window.StartPosition = 'CenterParent'
    $window.FormBorderStyle = 'FixedDialog'
    $window.MaximizeBox = $false
    $window.MinimizeBox = $false
    $window.Font = $form.Font
    $window.BackColor = $form.BackColor
    $window.ForeColor = $form.ForeColor
    $inputBox = [Windows.Forms.TextBox]::new()
    $inputBox.SetBounds(16, 16, 516, 30)
    $inputBox.AccessibleName = '要计算的算式'
    $inputBox.AccessibleDescription = 'ans 引用当前值，m1 至 m4 引用记忆寄存器'
    $inputBox.MaxLength = 4096
    $inputBox.Text = $InitialExpression
    $inputBox.SelectionStart = $inputBox.TextLength
    $window.Controls.Add($inputBox)
    $status = [Windows.Forms.Label]::new()
    $status.SetBounds(16, 53, 516, 34)
    $window.Controls.Add($status)
    $submit = [Windows.Forms.Button]::new()
    $submit.Text = '计算并使用'
    $submit.SetBounds(402, 92, 130, 34)
    $window.Controls.Add($submit)
    $window.AcceptButton = $submit
    $preview = [Windows.Forms.Button]::new()
    $preview.Text = '预览结果'
    $preview.SetBounds(260, 92, 130, 34)
    $window.Controls.Add($preview)
    $autoPreview = [Windows.Forms.CheckBox]::new()
    $autoPreview.Text = '自动预览'
    $autoPreview.SetBounds(16, 92, 142, 34)
    $window.Controls.Add($autoPreview)
    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 250
    $dialog = @{
        Window = $window; Input = $inputBox; Status = $status; Submit = $submit; Preview = $preview
        AutoPreview = $autoPreview; Timer = $timer
    }
    $run = {
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $controls.Timer.Stop()
        $isAutomatic = $sender -eq $controls.Timer
        if ($isAutomatic -and (!$controls.AutoPreview.Checked -or !$controls.Input.Text.Trim())) { return }
        $errorIndex = -1
        $previewValue = ''
        $isPreview = $isAutomatic -or $sender -eq $controls.Preview
        $message = if ($isPreview) {
            Submit-CalculatorExpression $controls.Input.Text -ErrorIndex ([ref]$errorIndex) -PreviewValue ([ref]$previewValue)
        } else {
            Submit-CalculatorExpression $controls.Input.Text -ErrorIndex ([ref]$errorIndex)
        }
        if ($message) {
            $controls.Status.Text = $message
            if (!$isAutomatic) {
                [void]$controls.Input.Focus()
                if ($errorIndex -ge 0) {
                    $length = [int]($errorIndex -lt $controls.Input.TextLength)
                    $controls.Input.Select($errorIndex, $length)
                }
            }
            return
        }
        if ($isPreview) {
            $controls.Status.Text = "预览结果 $previewValue"
            return
        }
        $controls.Window.DialogResult = [Windows.Forms.DialogResult]::OK
    }
    foreach ($button in @($submit, $preview)) {
        $button.Tag = $dialog
        $button.Add_Click($run)
    }
    $timer.Tag = $dialog
    $timer.Add_Tick($run)
    $window.Tag = $dialog
    $window.Add_Disposed({ param($sender, $eventArgs) $sender.Tag.Timer.Dispose() })
    $schedulePreview = {
        param($sender, $eventArgs)
        $controls = $sender.Tag
        $controls.Status.Text = ''
        $controls.Timer.Stop()
        if ($controls.AutoPreview.Checked -and $controls.Input.Text.Trim()) { $controls.Timer.Start() }
    }
    $inputBox.Tag = $dialog
    $inputBox.Add_TextChanged($schedulePreview)
    $autoPreview.Tag = $dialog
    $autoPreview.Add_CheckedChanged($schedulePreview)
    return $dialog
}

function Open-CalculatorExpressionDialog([string]$InitialExpression = '') {
    $dialog = New-CalculatorExpressionDialog $InitialExpression
    try { [void]$dialog.Window.ShowDialog($form) }
    finally { $dialog.Window.Dispose() }
}

$expressionButton = New-CalculatorActionButton '输入算式' 16 728 330
$expressionButton.AccessibleDescription = '快捷键 Ctrl+E'
$expressionButton.Add_Click({ Open-CalculatorExpressionDialog })

$memorySlot = [Windows.Forms.ComboBox]::new()
$memorySlot.DropDownStyle = 'DropDownList'
$memorySlot.AccessibleName = '记忆寄存器'
$memorySlot.Items.AddRange([object[]]@('记忆 M1', '记忆 M2', '记忆 M3', '记忆 M4'))
$memorySlot.SetBounds(186, 689, 160, 34)
$memorySlot.DropDownWidth = 254
$memorySlot.SelectedIndex = 0
$memorySlot.Add_SelectedIndexChanged({
    param($sender, $eventArgs)
    if ($null -ne $session.Process -and !$state.UpdatingMemory) { Apply-CalculatorCommand ([string][char](106 + $sender.SelectedIndex)) }
})
$memorySlot.Add_DropDown({
    param($sender, $eventArgs)
    if ($null -eq $session.Process) { return }
    try {
        if (!$session.EditDisplay) {
            Send-BaizeCommand 'JW'
            $session.EditDisplay = $true
        } else {
            Send-BaizeCommand 'W'
        }
        $frameClock = [Diagnostics.Stopwatch]::StartNew()
        $labels = @(
            for ($index = 1; $index -le 4; $index++) {
                $value = [long]::Parse((Read-BaizeFrameLine $session.Process.StandardOutput $frameClock), $invariant)
                "M$index  $(([decimal]$value / 1000000000).ToString('0.#########', $invariant))"
            }
        )
        $selected = $sender.SelectedIndex
        $state.UpdatingMemory = $true
        try {
            for ($index = 0; $index -lt $labels.Count; $index++) { $sender.Items[$index] = $labels[$index] }
            $sender.SelectedIndex = $selected
        } finally { $state.UpdatingMemory = $false }
    } catch {
        Stop-BaizeSession
        $expressionLabel.Text = '无法读取记忆寄存器'
        if ($Verify) { throw }
    }
})
$form.Controls.Add($memorySlot)

function Press-CalculatorKey([string]$Key) {
    if ($Key -ne 'C' -and $null -eq $session.Process) { return }
    Apply-CalculatorCommand $Key
}

function Apply-CalculatorCommand([string]$Command, [switch]$PassThru) {
    try {
        if ($null -eq $session.Process) { Start-BaizeSession }
        $result = Invoke-BaizeKey $Command
        if ($Command[0] -ceq 'U') { return $result }
        if ($result.Code -ne 0 -and $Command[0] -in @('P', 'T')) {
            $expressionLabel.Text = if ($result.Code -eq 1) {
                if ($Command[0] -eq 'T') { '计算错误：无效算式' } else { '请粘贴单个有效数字' }
            } else { $result.Output }
            if ($PassThru) { return $result }
            return
        }
        $resultLabel.Text = $result.Output
        $expressionLabel.Text = $result.Expression
        $state.CanCopy = $result.Code -eq 0
        $state.InternalValue = $result.InternalValue
        if ($null -ne $result.HistoryEntry) {
            [void]$historyList.Items.Insert(0, $result.HistoryEntry)
            if ($historyList.Items.Count -gt 50) { $historyList.Items.RemoveAt(50) }
            if (!(Save-CalculatorHistory $result.HistoryEntry)) {
                $expressionLabel.Text = '历史暂未保存，下次计算时重试'
            }
        }
        if ($PassThru) { return $result }
    } catch {
        Stop-BaizeSession
        $state.CanCopy = $false
        $expressionLabel.Text = ''
        $resultLabel.Text = "计算进程通信失败，按清除重试"
        if ($Verify) { throw }
    }
}

for ($i = 0; $i -lt $keys.Count; $i++) {
    $key = $keys[$i]
    $button = [Windows.Forms.Button]::new()
    $button.Text = $key
    $button.TabStop = $false
    $button.Tag = switch ($key) {
        '÷' { '/' }
        '×' { '*' }
        '−' { '-' }
        '±' { '~' }
        '清除' { 'C' }
        '退格' { 'B' }
        'CE' { 'E' }
        '1/x' { 'R' }
        'x²' { 'S' }
        '√' { 'Q' }
        'MC' { 'X' }
        'MR' { 'G' }
        'M+' { 'A' }
        'M−' { 'D' }
        'MS' { 'M' }
        default { $key }
    }
    if ($i -lt $memoryKeys.Count) {
        $button.SetBounds(16 + 67 * $i, 144, 61, 40)
    } else {
        $position = $i - $memoryKeys.Count
        $column = $position % 4
        $row = [Math]::Floor($position / 4)
        $button.SetBounds(16 + 84 * $column, 194 + 61 * $row, 78, 54)
    }
    $button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = [Drawing.ColorTranslator]::FromHtml('#2B3940')
    if ($key -eq '=') {
        $button.BackColor = [Drawing.ColorTranslator]::FromHtml('#F1C56C')
        $button.ForeColor = [Drawing.ColorTranslator]::FromHtml('#192128')
    }
    $button.Add_Click({ param($sender, $eventArgs) Press-CalculatorKey $sender.Tag })
    $form.Controls.Add($button)
    $buttons[$key] = $button
}

$form.Add_KeyPress({
    param($sender, $eventArgs)
    $key = switch ([string]$eventArgs.KeyChar) {
        '×' { '*' }
        '÷' { '/' }
        '−' { '-' }
        '±' { '~' }
        '@' { 'Q' }
        '√' { 'Q' }
        '²' { 'S' }
        default { ([string]$eventArgs.KeyChar).ToUpperInvariant() }
    }
    if ($key -match '^[0-9+*/=.%~QSR-]$') {
        Press-CalculatorKey $key
        $eventArgs.Handled = $true
    }
})
$compactButton = New-CalculatorActionButton '紧凑' 100 14 76
$compactButton.Height = 30
$standardResultFont = $resultLabel.Font
$compactResultFont = [Drawing.Font]::new($standardResultFont.FontFamily, 18)
$smallResultFont = [Drawing.Font]::new($standardResultFont.FontFamily, 14)
function Resize-CalculatorResultText {
    $font = if ($state.Compact) { $compactResultFont } else { $standardResultFont }
    if ([Windows.Forms.TextRenderer]::MeasureText($resultLabel.Text, $font).Width -gt $resultLabel.ClientSize.Width) {
        $font = $smallResultFont
    }
    $resultLabel.Font = $font
}
$resultLabel.Add_TextChanged({ Resize-CalculatorResultText })
$resultLabel.Add_SizeChanged({ Resize-CalculatorResultText })
$compactButton.AccessibleName = '切换紧凑视图'
$compactButton.AccessibleDescription = '快捷键 Ctrl+Shift+T'
$standardBounds = @{}
foreach ($key in $keys) { $standardBounds[$key] = $buttons[$key].Bounds }
$compactKeys = @(
    '%', 'CE', '清除', '退格',
    '7', '8', '9', '÷',
    '4', '5', '6', '×',
    '1', '2', '3', '−',
    '±', '0', '.', '+'
)
$fullControls = @($copyButton, $historyButton, $programmerButton, $converterButton, $dateButton, $scientificButton, $graphButton, $expressionButton, $memorySlot)
function Switch-CalculatorCompactView {
    $state.Compact = !$state.Compact
    $form.SuspendLayout()
    try {
        foreach ($control in $fullControls) { $control.Visible = !$state.Compact }
        if ($state.Compact) {
            foreach ($key in $keys) { $buttons[$key].Visible = $false }
            for ($index = 0; $index -lt $compactKeys.Count; $index++) {
                $button = $buttons[$compactKeys[$index]]
                $button.SetBounds((12 + 69 * ($index % 4)), (101 + 43 * [int][math]::Floor($index / 4)), 65, 39)
                $button.Visible = $true
            }
            $buttons['='].SetBounds(12, 316, 272, 40)
            $buttons['='].Visible = $true
            $expressionLabel.SetBounds(182, 14, 102, 30)
            $resultLabel.SetBounds(12, 47, 272, 49)
            $form.ClientSize = [Drawing.Size]::new(296, 369)
            $compactButton.Text = '展开'
        } else {
            foreach ($key in $keys) {
                $buttons[$key].Bounds = $standardBounds[$key]
                $buttons[$key].Visible = $true
            }
            $expressionLabel.SetBounds(182, 14, 166, 30)
            $resultLabel.SetBounds(16, 44, 332, 92)
            $compactButton.Text = '紧凑'
        }
        Update-CalculatorHistoryLayout
    } finally {
        $form.ResumeLayout()
    }
}
$compactButton.Add_Click({ Switch-CalculatorCompactView })

$form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Control -and [int]$eventArgs.KeyCode -eq 67) {
        Copy-CalculatorResult -FullPrecision:$eventArgs.Shift
        $eventArgs.SuppressKeyPress = $true
        return
    }
    if ($eventArgs.Control -and $eventArgs.KeyCode -eq [Windows.Forms.Keys]::T) {
        if ($eventArgs.Shift) {
            Switch-CalculatorCompactView
            $eventArgs.SuppressKeyPress = $true
            return
        }
        $pinButton.Checked = !$pinButton.Checked
        $eventArgs.SuppressKeyPress = $true
        return
    }
    if ($eventArgs.Control -and $eventArgs.KeyCode -eq [Windows.Forms.Keys]::E) {
        $eventArgs.SuppressKeyPress = $true
        Open-CalculatorExpressionDialog
        return
    }
    if ($eventArgs.Control -and [int]$eventArgs.KeyCode -eq 86) {
        Paste-CalculatorValue -Expression:$eventArgs.Shift
        $eventArgs.SuppressKeyPress = $true
        return
    }
    if ($eventArgs.Modifiers -eq [Windows.Forms.Keys]::Control) {
        $memoryCommand = switch ($eventArgs.KeyCode) {
            'L' { 'MC' }
            'R' { 'MR' }
            'P' { 'M+' }
            'Q' { 'M−' }
            'M' { 'MS' }
        }
        if ($memoryCommand) {
            Press-CalculatorKey $buttons[$memoryCommand].Tag
            $eventArgs.SuppressKeyPress = $true
            return
        }
    }
    if ($historyList.Focused -and [int]$eventArgs.KeyCode -eq 13) { return }
    $key = switch ([int]$eventArgs.KeyCode) {
        13 { '=' }
        8 { 'B' }
        27 { 'C' }
        46 { 'E' }
        110 { '.' } # 小键盘小数键使用点号。
        120 { '~' }
    }
    if ($null -ne $key) {
        Press-CalculatorKey $key
        $eventArgs.SuppressKeyPress = $true
    }
})

try {
    Start-BaizeSession
    if ($Verify) {
        $sessionPid = $session.Process.Id
        # W returns four lines, then the live worker waits for the next command.
        Send-BaizeCommand 'W'
        $frameClock = [Diagnostics.Stopwatch]::StartNew()
        $reader = $session.Process.StandardOutput
        for ($line = 0; $line -lt 4; $line++) {
            if ((Read-BaizeFrameLine $reader $frameClock) -ne '0') { throw '空记忆寄存器响应错误' }
        }
        $timedOut = $false
        try { [void](Read-BaizeFrameLine $reader $frameClock -TimeoutMs 200) }
        catch {
            if ($_.Exception.Message -ne '白泽计算进程未返回完整结果') { throw }
            $timedOut = $true
        }
        if (!$timedOut -or $session.Process.HasExited) { throw '应对存活进程的不完整响应超时' }
        Stop-BaizeSession
        Start-BaizeSession
        $sessionPid = $session.Process.Id
        # Raise actual WinForms control events without opening an interactive window.
        $binding = [Reflection.BindingFlags]'Instance, NonPublic'
        $click = [Windows.Forms.Button].GetMethod('OnClick', $binding)
        $keypress = [Windows.Forms.Form].GetMethod('OnKeyPress', $binding)
        $keydown = [Windows.Forms.Form].GetMethod('OnKeyDown', $binding)
        $pinButton.Checked = $true
        if (!$form.TopMost -or $pinButton.Text -ne '取消置顶') { throw '窗口置顶没有生效' }
        $pinKeys = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::T)
        [void]$keydown.Invoke($form, @($pinKeys))
        if ($form.TopMost -or $pinButton.Checked -or !$pinKeys.SuppressKeyPress) { throw 'Ctrl+T 没有关闭置顶' }
        Press-CalculatorKey '2'
        Press-CalculatorKey '+'
        [void]$click.Invoke($compactButton, @([EventArgs]::Empty))
        if (!$state.Compact -or $form.ClientSize.Width -ne 296 -or $buttons['='].Bottom -gt $form.ClientSize.Height) {
            throw '紧凑视图布局错误'
        }
        Press-CalculatorKey '3'
        $compactKeysEvent = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Shift -bor [Windows.Forms.Keys]::T)
        [void]$keydown.Invoke($form, @($compactKeysEvent))
        if ($state.Compact -or $form.TopMost -or $form.ClientSize.Width -ne 364 -or $buttons['='].Bounds -ne $standardBounds['=']) {
            throw '快捷键未恢复标准布局'
        }
        Press-CalculatorKey '='
        if ($resultLabel.Text -ne '5') { throw '切换视图丢失了待完成的运算' }
        Press-CalculatorKey 'C'
        foreach ($key in '2+*3'.ToCharArray()) { Press-CalculatorKey $key }
        if ($expressionLabel.Text -ne '2 ×') { throw '算式仍显示已替换的运算符' }
        Press-CalculatorKey '='
        if ($expressionLabel.Text -ne '2 × 3 =' -or $resultLabel.Text -ne '6') { throw '算式未显示首次结算' }
        Press-CalculatorKey '='
        if ($expressionLabel.Text -ne '6 × 3 =' -or $resultLabel.Text -ne '18') { throw '算式未更新重复结算' }
        Press-CalculatorKey 'C'
        [void]$click.Invoke($historyClear, @([EventArgs]::Empty))
        foreach ($key in @('2', '+', '3', '×', '4', '=')) {
            [void]$click.Invoke($buttons[$key], @([EventArgs]::Empty))
        }
        if ($resultLabel.Text -ne '20') { throw "逐步运算验收失败：$($resultLabel.Text)" }
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in '2+3=='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        if ($resultLabel.Text -ne '8') { throw "连续等号验收失败：$($resultLabel.Text)" }
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in @('2','0','0','+','1','0','%','退格','=')) {
            [void]$click.Invoke($buttons[$key], @([EventArgs]::Empty))
        }
        if ($resultLabel.Text -ne '220') { throw "百分号验收失败：$($resultLabel.Text)" }
        foreach ($key in 'C0.00000001/0.00000001%='.ToCharArray()) { Press-CalculatorKey $key }
        if ($resultLabel.Text -ne '100' -or $expressionLabel.Text -ne '0.00000001 ÷ 0.00000001% =' -or
            $historyList.Items[0].Expression -ne '0.00000001 ÷ 0.00000001%') {
            throw '百分比除数丢失精度或历史显示错误'
        }
        $historyList.SelectedIndex = 0
        [void]$click.Invoke($historyCopy, @([EventArgs]::Empty))
        Press-CalculatorKey 'C'
        $replayMessage = Submit-CalculatorExpression $copyState.Text
        if ($replayMessage -or $resultLabel.Text -ne '100') { throw '百分比除法历史算式无法精确重算' }
        foreach ($key in 'C1000000000*0.00000001%='.ToCharArray()) { Press-CalculatorKey $key }
        if ($resultLabel.Text -ne '0.1' -or $historyList.Items[0].Expression -ne '1,000,000,000 × 0.00000001%') {
            throw '百分比乘数精度或历史错误'
        }
        Press-CalculatorKey 'C'
        $replayMessage = Submit-CalculatorExpression $historyList.Items[0].Expression
        if ($replayMessage -or $resultLabel.Text -ne '0.1') { throw '百分比乘法历史算式无法精确重算' }
        $replayMessage = Submit-CalculatorExpression '200+10%-10%'
        if ($replayMessage -or $resultLabel.Text -ne '198') { throw '加减百分比未使用当前左值' }
        $replayMessage = Submit-CalculatorExpression '10%+2*(10%)'
        if ($replayMessage -or $resultLabel.Text -ne '0.3') { throw '首项或括号内的百分比求值失败' }
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in '1/0='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        if ($resultLabel.Text -ne '计算错误：不能除以零') { throw "键盘除零验收失败：$($resultLabel.Text)" }
        [void]$keydown.Invoke($form, @([Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Escape)))
        foreach ($key in '0.1+0.29'.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        [void]$keydown.Invoke($form, @([Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Back)))
        [void]$keydown.Invoke($form, @([Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Enter)))
        if ($resultLabel.Text -ne '0.3') { throw "小数和错误恢复验收失败：$($resultLabel.Text)" }
        Press-CalculatorKey 'C'
        [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new('1')))
        $decimalEvent = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Decimal)
        [void]$keydown.Invoke($form, @($decimalEvent))
        if (!$decimalEvent.SuppressKeyPress) { throw '小键盘小数点应拦截区域分隔符' }
        foreach ($key in '5×4÷2−1='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        if ($resultLabel.Text -ne '2') { throw "小键盘小数点和运算符验收失败：$($resultLabel.Text)" }
        foreach ($step in @(@('12', 'M', '12'), @('3', 'P', '3'), @('2', 'Q', '2'),
                            @('', 'R', '13'), @('', 'L', '0'), @('', 'R', '0'))) {
            Press-CalculatorKey 'C'
            foreach ($digit in $step[0].ToCharArray()) { Press-CalculatorKey ([string]$digit) }
            $shortcut = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]$step[1])
            [void]$keydown.Invoke($form, @($shortcut))
            if (!$shortcut.SuppressKeyPress -or $resultLabel.Text -ne $step[2]) {
                throw "记忆快捷键验收失败：Ctrl+$($step[1])，结果 $($resultLabel.Text)"
            }
        }
        foreach ($case in @(@('9@', '3'), @('9√', '3'), @('4²', '16'), @('8r', '0.125'))) {
            Press-CalculatorKey 'C'
            foreach ($key in $case[0].ToCharArray()) {
                $keyEvent = [Windows.Forms.KeyPressEventArgs]::new($key)
                [void]$keypress.Invoke($form, @($keyEvent))
                if (!$keyEvent.Handled) { throw "标准运算快捷键未处理：$key" }
            }
            if ($resultLabel.Text -ne $case[1]) { throw "标准运算快捷键结果错误：$($case[0])" }
        }
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in '1/3='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        if ($resultLabel.Text -ne '0.33333333') { throw "八位除法验收失败：$($resultLabel.Text)" }
        foreach ($key in '*3='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        if ($resultLabel.Text -ne '1') { throw "连续运算精度验收失败：$($resultLabel.Text)" }
        if ($historyList.Items[0].Expression -ne '0.333333333 × 3') {
            throw '历史算式未保存实际使用的九位操作数'
        }
        Press-CalculatorKey 'C'
        $replayMessage = Submit-CalculatorExpression $historyList.Items[0].Expression
        if ($replayMessage -or $resultLabel.Text -ne '1') { throw '历史算式重算丢失内部精度' }
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in '0+2147483648'.ToCharArray()) { Press-CalculatorKey ([string]$key) }
        if ($resultLabel.Text -ne '214,748,364' -or $expressionLabel.Text -ne '输入超出计算器范围') {
            throw '超范围整数输入应保留原操作数'
        }
        Press-CalculatorKey '7'
        Press-CalculatorKey '.'
        Press-CalculatorKey '1'
        if ($resultLabel.Text -ne '2,147,483,647.' -or $expressionLabel.Text -ne '输入超出计算器范围') {
            throw '超范围小数输入应保留原操作数'
        }
        Press-CalculatorKey '='
        if ($resultLabel.Text -ne '2,147,483,647') { throw '超限输入破坏了待运算' }
        Press-CalculatorKey 'C'
        foreach ($key in '1+~0.00000000'.ToCharArray()) { Press-CalculatorKey ([string]$key) }
        if ($expressionLabel.Text -eq '最多输入八位小数') { throw '第八位小数仍应接受' }
        Press-CalculatorKey '9'
        if ($resultLabel.Text -ne '-0.00000000' -or $expressionLabel.Text -ne '最多输入八位小数') {
            throw '超出小数输入位数时应保留原数字并提示'
        }
        Press-CalculatorKey 'B'
        if ($expressionLabel.Text -ne '1 +' -or $resultLabel.Text -ne '-0.0000000') {
            throw '退格后应恢复待运算表达式和输入'
        }
        Press-CalculatorKey '='
        if ($resultLabel.Text -ne '1') { throw '小数位数提示破坏了待运算' }
        Press-CalculatorKey 'C'
        foreach ($key in '0.12345678+0.12345678='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        if ($resultLabel.Text -ne '0.24691356') { throw "长小数验收失败：$($resultLabel.Text)" }
        foreach ($button in $buttons.Values) {
            if (!$form.ClientRectangle.Contains($button.Bounds)) { throw "按钮超出窗口：$($button.Text)" }
        }
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in @('2', '√')) {
            [void]$click.Invoke($buttons[$key], @([EventArgs]::Empty))
        }
        if ($resultLabel.Text -ne '1.41421356') { throw "平方根验收失败：$($resultLabel.Text)" }
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in @('1','2','MS','清除','3','+','MR','=')) {
            [void]$click.Invoke($buttons[$key], @([EventArgs]::Empty))
        }
        if ($resultLabel.Text -ne '15') { throw "记忆键验收失败：$($resultLabel.Text)" }
        $memorySlot.SelectedIndex = 1
        Press-CalculatorKey 'C'
        Press-CalculatorKey '7'
        Press-CalculatorKey 'M'
        $memorySlot.SelectedIndex = 0
        Press-CalculatorKey 'G'
        if ($resultLabel.Text -ne '12') { throw '切换寄存器后 M1 丢失' }
        $memorySlot.SelectedIndex = 1
        Press-CalculatorKey 'G'
        if ($resultLabel.Text -ne '7') { throw 'M2 未独立保存' }
        Press-CalculatorKey '+'
        $dropDown = [Windows.Forms.ComboBox].GetMethod('OnDropDown', $binding)
        [void]$dropDown.Invoke($memorySlot, @([EventArgs]::Empty))
        if ($memorySlot.Items[0] -ne 'M1  12' -or $memorySlot.Items[1] -ne 'M2  7' -or
            $memorySlot.Items[2] -ne 'M3  0' -or $memorySlot.Items[3] -ne 'M4  0' -or $memorySlot.SelectedIndex -ne 1) {
            throw '记忆寄存器预览错误'
        }
        Press-CalculatorKey '2'
        Press-CalculatorKey '='
        if ($resultLabel.Text -ne '9') { throw '记忆预览改变了待完成运算' }
        Press-CalculatorKey 'X'
        $memorySlot.SelectedIndex = 0
        Press-CalculatorKey 'G'
        if ($resultLabel.Text -ne '12') { throw '清除 M2 意外影响 M1' }
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in @('2','0','+','3','5','CE','6','=')) {
            [void]$click.Invoke($buttons[$key], @([EventArgs]::Empty))
        }
        if ($resultLabel.Text -ne '26') { throw "清除单项输入验收失败：$($resultLabel.Text)" }
        [void]$click.Invoke($historyClear, @([EventArgs]::Empty))
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in '2+3=='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        if ($historyList.Items.Count -ne 2 -or
            $historyList.Items[0].ToString() -ne '5 + 3 = 8' -or
            $historyList.Items[1].ToString() -ne '2 + 3 = 5') { throw '计算历史内容错误' }
        [void]$click.Invoke($historyButton, @([EventArgs]::Empty))
        if ($form.ClientSize.Width -ne 692) { throw '历史区域未展开' }
        $historyList.SelectedIndex = 1
        [void]$click.Invoke($historyRestore, @([EventArgs]::Empty))
        if ($resultLabel.Text -ne '5' -or $historyList.Items.Count -ne 2) {
            throw '使用历史结果失败或生成额外记录'
        }
        [void]$click.Invoke($copyButton, @([EventArgs]::Empty))
        if ($copyState.Text -ne '5') { throw '复制结果事件未传递当前数值' }
        $copyState.Text = $null
        [void]$keydown.Invoke($form, @([Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::C)))
        if ($copyState.Text -ne '5') { throw 'Ctrl+C 未复制当前数值' }
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in '1/0='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        [void]$click.Invoke($copyButton, @([EventArgs]::Empty))
        if ($historyList.Items.Count -ne 2 -or $copyState.Text -ne '5') {
            throw '出错运算进入了历史或复制结果'
        }
        $historyReader = [IO.File]::Open($historyPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            [void]$click.Invoke($historyClear, @([EventArgs]::Empty))
            if ($historyList.Items.Count -ne 2 -or @(Read-CalculatorHistory).Count -ne 2 -or
                $expressionLabel.Text -ne '无法清空计算历史，请重试') { throw '历史文件无法删除时应保留历史并显示提示' }
        } finally {
            $historyReader.Dispose()
        }
        [void]$click.Invoke($historyClear, @([EventArgs]::Empty))
        if ($historyList.Items.Count -ne 0 -or [IO.File]::Exists($historyPath) -or
            $expressionLabel.Text -eq '无法清空计算历史，请重试') { throw '历史清空验收失败' }
        [void]$click.Invoke($historyClear, @([EventArgs]::Empty))
        Save-CalculatorHistory ([CalculationHistoryEntry]::new('1 + 1', '2', 2000000000L)) | Out-Null
        $historyReader = [IO.File]::Open($historyPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            foreach ($key in '3+4='.ToCharArray()) {
                [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
            }
            if ($resultLabel.Text -ne '7' -or $historyList.Items[0].Result -ne '7' -or
                $expressionLabel.Text -ne '历史暂未保存，下次计算时重试' -or
                @(Read-CalculatorHistory).Count -ne 1) { throw '历史保存失败时应保留结果和待保存记录' }
        } finally {
            $historyReader.Dispose()
        }
        foreach ($key in '8+1='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        $savedHistory = @(Read-CalculatorHistory)
        if (($savedHistory.Result -join ',') -ne '9,7,2' -or $pendingHistory.Count -ne 0) {
            throw '历史解锁后应按顺序补存且不重复'
        }
        [void]$click.Invoke($historyClear, @([EventArgs]::Empty))
        [void]$click.Invoke($buttons['清除'], @([EventArgs]::Empty))
        foreach ($key in '1/3='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        Stop-BaizeSession
        Start-BaizeSession
        $sessionPid = $session.Process.Id
        $historyList.Items.Clear()
        foreach ($entry in (Read-CalculatorHistory)) { [void]$historyList.Items.Add($entry) }
        if ($historyList.Items.Count -ne 1 -or $historyList.Items[0].InternalValue -ne 333333333L) {
            throw '历史重载没有保留定点内部值'
        }
        $historyList.SelectedIndex = 0
        [void]$click.Invoke($historyRestore, @([EventArgs]::Empty))
        if ($resultLabel.Text -ne '0.33333333' -or $historyList.Items.Count -ne 1) {
            throw '带保护位的历史恢复失败或生成了额外记录'
        }
        foreach ($key in '*3='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        if ($resultLabel.Text -ne '1') { throw "历史丢失内部精度：$($resultLabel.Text)" }
        $programmer = New-ProgrammerDialog
        try {
            $programmer.Operation.SelectedItem = 'XOR'
            $programmer.Left.Text = '0xF_F'
            $programmer.Right.Text = '0F'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  000000F0' -or $programmer.Result.Text -notmatch 'DEC  240' -or
                $programmer.Result.Text -notmatch 'OCT  360' -or
                $programmer.Result.Text -notmatch 'BIN  00000000000000000000000011110000') {
                throw "程序员模式进制显示错误：$($programmer.Result.Text)"
            }
            $programmer.Operation.SelectedItem = '字节序反转'
            if (!$programmer.Right.ReadOnly -or $programmer.Right.TabStop -or
                $programmer.RightLabel.Text -ne '右值（未使用）' -or $programmer.Right.Text -ne '0F') {
                throw '单操作数模式未正确标记或保留右值'
            }
            $programmer.Left.Text = '0x12_34_56_78'
            $programmer.Right.Text = '不参与运算'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  78563412') { throw '程序员模式字节序反转失败' }
            $programmerCopy = [Windows.Forms.KeyEventArgs]::new(
                [Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Shift -bor [Windows.Forms.Keys]::C)
            [void]$keydown.Invoke($programmer.Window, @($programmerCopy))
            if (!$programmerCopy.SuppressKeyPress) { throw '程序员复制快捷键未处理' }
            if ($copyState.Text -ne '0x78563412') { throw '程序员结果未复制为代码格式' }
            $programmer.Left.Text = $copyState.Text
            if ($programmer.CopyOperand.Enabled) { throw '输入修改后仍可复制旧结果' }
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  12345678') { throw '复制的字节序结果无法回用' }
            $programmer.Base.SelectedItem = '10'
            if ($programmer.Base.SelectedItem -ne '10' -or $programmer.Left.Text -ne '2018915346' -or
                $programmer.Right.Text -ne '不参与运算') { throw '单操作数运算切换进制时处理了无关右值' }
            $copyState.Input = '0x78563412'
            $operandKeyDown = [Windows.Forms.TextBox].GetMethod('OnKeyDown', $binding)
            $prefixedPaste = [Windows.Forms.KeyEventArgs]::new(
                [Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Shift -bor [Windows.Forms.Keys]::V)
            [void]$operandKeyDown.Invoke($programmer.Left, @($prefixedPaste))
            if (!$prefixedPaste.SuppressKeyPress -or $programmer.Left.Text -ne '2018915346' -or
                $programmer.Base.SelectedItem -ne '10') { throw '跨进制粘贴未保留数值或当前进制' }
            $copyState.Input = '0b102'
            [void]$operandKeyDown.Invoke($programmer.Left, @($prefixedPaste))
            if ($programmer.Left.Text -ne '2018915346') { throw '无效前缀粘贴修改了操作数' }
            $programmer.Base.SelectedItem = '16'
            if ($programmer.Left.MaxLength -lt 129 -or $programmer.Right.MaxLength -lt 129) {
                throw '输入框无法容纳带前缀和分隔符的 QWORD 二进制数'
            }
            $programmer.Left.Text = '0x00_F0_00_00'
            foreach ($case in @(@('置位计数', 4), @('前导零计数', 8), @('尾随零计数', 20))) {
                $programmer.Operation.SelectedItem = $case[0]
                [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
                if ($programmer.Result.Text -notmatch ("DEC  {0}`r?`n" -f $case[1])) {
                    throw "程序员模式位计数失败：$($case[0])"
                }
            }
            $programmer.Operation.SelectedItem = '位序反转'
            $programmer.Left.Text = '0x12'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  48000000') { throw 'DWORD 位序反转失败' }
            $programmer.Operation.SelectedItem = '差异位计数'
            $programmer.Left.Text = '0xF0'
            $programmer.Right.Text = '0x55'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if (($programmer.Result.Lines[1]) -ne 'DEC  4') { throw '差异位计数失败' }
            $programmer.Operation.SelectedItem = '提取位字段'
            $programmer.Left.Text = '0xABCD'
            $programmer.Right.Text = '4:8'
            $programmer.Base.SelectedItem = '10'
            if ($programmer.Right.Text -ne '4:8') { throw '进制切换改写了位字段范围' }
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if (($programmer.Result.Lines[1]) -ne 'DEC  188') { throw '位字段提取失败' }
            $programmer.Operation.SelectedItem = '提取有符号位字段'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Lines[0] -ne 'HEX  FFFFFFBC' -or $programmer.Result.Lines[2] -ne 'SIGNED  -68') {
                throw '有符号位字段未按所选字长扩展'
            }
            $programmer.Operation.SelectedItem = '写入位字段'
            $programmer.Right.Text = '4:8=0x42'
            $programmer.Base.SelectedItem = '16'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Right.Text -ne '4:8=0x42' -or $programmer.Result.Lines[0] -ne 'HEX  0000A42D') {
                throw '写入位字段失败或改写了字段范围'
            }
            $programmer.Right.Text = '0'
            $programmer.Operation.SelectedItem = '逻辑右移'
            $programmer.Left.Text = '80000000'
            $programmer.Right.Text = '1'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  40000000') { throw 'DWORD 逻辑右移失败' }
            $programmer.Operation.SelectedItem = '循环左移'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  00000001') { throw 'DWORD 循环左移失败' }
            $programmer.Operation.SelectedItem = '减法'
            $programmer.Left.Text = '0'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  FFFFFFFF') { throw 'DWORD 减法回绕失败' }
            $programmer.Operation.SelectedItem = '逻辑右移'
            $programmer.Left.Text = '80000000'
            $programmer.Right.Text = '32'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch '移位数须为非负十进制，且小于所选字长') { throw '移位边界提示错误' }
            $programmer.Width.SelectedItem = 'QWORD'
            $programmer.Base.SelectedItem = '10'
            $programmer.Operation.SelectedItem = '进制转换'
            $programmer.Left.Text = '18446744073709551615'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  FFFFFFFFFFFFFFFF' -or
                $programmer.Result.Text -notmatch 'DEC  18446744073709551615' -or
                $programmer.Result.Text -notmatch 'BIN  1{64}$') { throw 'QWORD 无符号最大值显示失败' }
            $programmer.Operation.SelectedItem = '无符号除法'
            $programmer.Right.Text = '2'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'DEC  9223372036854775807') { throw 'QWORD 无符号除法失败' }
            $programmer.Operation.SelectedItem = '无符号取余'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'DEC  1\r?\n') { throw 'QWORD 无符号取余失败' }
            $programmer.Operation.SelectedItem = '乘法'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  FFFFFFFFFFFFFFFE') { throw 'QWORD 乘法回绕失败' }
            $programmer.Left.Text = '-7'
            $programmer.Right.Text = '3'
            $programmer.Operation.SelectedItem = '有符号除法'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'SIGNED  -2\r?\n') { throw 'QWORD 有符号除法失败' }
            $programmer.Operation.SelectedItem = '有符号取余'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'SIGNED  -1\r?\n') { throw 'QWORD 有符号取余失败' }
            $programmer.Left.Text = '0'
            $programmer.Width.SelectedItem = 'BYTE'
            $programmer.Base.SelectedItem = '16'
            $programmer.Operation.SelectedItem = '左移'
            $programmer.Left.Text = '80'
            $programmer.Right.Text = '1'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  00' -or
                $programmer.Result.Text -notmatch 'BIN  0{8}$') { throw 'BYTE 移位截断失败' }
            $programmer.Operation.SelectedItem = '算术右移'
            $programmer.Base.SelectedItem = '10'
            $programmer.Left.Text = '-128'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  C0' -or $programmer.Result.Text -notmatch 'SIGNED  -64') {
                throw 'BYTE 算术右移或补码显示失败'
            }
            $programmer.Operation.SelectedItem = '加法'
            $programmer.Base.SelectedItem = '16'
            $programmer.Left.Text = '0xF_0'
            $programmer.Right.Text = '1'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if (!$programmer.UseResult.Enabled) { throw '成功结果应可复用' }
            [void]$click.Invoke($programmer.UseResult, @([EventArgs]::Empty))
            if ($programmer.Left.Text -ne 'F1' -or $programmer.Right.Text -ne '1' -or $programmer.UseResult.Enabled) {
                throw '结果回填未保持已有的进制和右操作数'
            }
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch 'HEX  F2') { throw '结果回填后连续计算失败' }
            $decimalShortcut = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::D2)
            [void]$keydown.Invoke($programmer.Window, @($decimalShortcut))
            if (!$decimalShortcut.SuppressKeyPress) { throw '程序员十进制快捷键未处理' }
            if ($programmer.UseResult.Enabled -or $programmer.Result.Text -ne '') { throw '进制变更后旧结果仍可复用' }
            if ($programmer.Left.Text -ne '241' -or $programmer.Right.Text -ne '1') { throw '切换进制改变了操作数' }
            $programmer.Operation.SelectedItem = '逻辑右移'
            if ($programmer.Right.ReadOnly -or !$programmer.Right.TabStop -or
                $programmer.RightLabel.Text -ne '移位数（十进制）') { throw '移位操作数未标明十进制' }
            $programmer.Right.Text = '16'
            $binaryShortcut = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::D4)
            [void]$keydown.Invoke($programmer.Window, @($binaryShortcut))
            if (!$binaryShortcut.SuppressKeyPress) { throw '程序员二进制快捷键未处理' }
            if ($programmer.Left.Text -ne '11110001' -or $programmer.Right.Text -ne '16') { throw '切换进制改变了移位数' }
            $programmer.Left.Text = '102'
            $decimalShortcut = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::D2)
            [void]$keydown.Invoke($programmer.Window, @($decimalShortcut))
            if (!$decimalShortcut.SuppressKeyPress) { throw '程序员十进制快捷键未处理' }
            if ($programmer.Base.SelectedItem -ne '2' -or $programmer.Left.Text -ne '102' -or
                $programmer.Result.Text -notmatch '进制未切换') { throw '无效进制切换修改了输入' }
            $programmer.Left.Text = '1'
            $programmer.Base.SelectedItem = '10'
            $programmer.Width.SelectedItem = 'QWORD'
            $programmer.Left.Text = '1'
            $programmer.Right.Text = '7'
            $editor = New-ProgrammerBitEditor $programmer
            try {
                if ($editor.Bits.Count -ne 64 -or $editor.Bits[0].Tag -ne 63 -or
                    $editor.Bits[0].Checked -or !$editor.Bits[63].Checked) {
                    throw '位编辑器初始状态错误'
                }
                $editor.Bits[0].Checked = $true
                $editor.Bits[63].Checked = $false
                [void]$click.Invoke($editor.Apply, @([EventArgs]::Empty))
                if ($programmer.Left.Text -ne '9223372036854775808' -or
                    $programmer.Right.Text -ne '7' -or $programmer.Base.SelectedItem -ne '10') {
                    throw '位编辑器没有保持进制和右操作数'
                }
            } finally {
                $editor.Window.Dispose()
            }
            $programmer.Left.Text = '0'
            $programmer.Width.SelectedItem = 'BYTE'
            $programmer.Base.SelectedItem = '16'
            $programmer.Left.Text = '100'
            if ($null -ne (New-ProgrammerBitEditor $programmer) -or
                $programmer.Result.Text -notmatch '超出所选字长') {
                throw '位编辑器没有拒绝越界输入'
            }
            $programmer.Operation.SelectedItem = '进制转换'
            $programmer.Width.SelectedItem = 'QWORD'
            $programmer.Left.Text = '8000000000000000'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if ($programmer.ToCalculator.Enabled -or $programmer.UnsignedToCalculator.Enabled) {
                throw '超出标准模式范围的 QWORD 可转入'
            }
            $programmer.Left.Text = 'FFFFFFFFFFFFFFFF'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if (!$programmer.ToCalculator.Enabled -or $programmer.UnsignedToCalculator.Enabled) {
                throw 'QWORD 的有符号与无符号范围检查混淆'
            }
            $byteShortcut = [Windows.Forms.KeyEventArgs]::new(
                [Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Shift -bor [Windows.Forms.Keys]::D1)
            [void]$keydown.Invoke($programmer.Window, @($byteShortcut))
            if (!$byteShortcut.SuppressKeyPress -or $programmer.Width.SelectedItem -ne 'BYTE') {
                throw '程序员字长快捷键未切换到 BYTE'
            }
            if ($programmer.Left.Text -ne 'FFFFFFFFFFFFFFFF' -or $programmer.Result.Text -notmatch '新字长' -or
                $programmer.ToCalculator.Enabled -or $programmer.UnsignedToCalculator.Enabled) {
                throw '缩小字长时应保留越界操作数并立即提示'
            }
            foreach ($key in 'C128'.ToCharArray()) { Press-CalculatorKey $key }
            [void]$click.Invoke($programmer.FromCalculator, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch '超出所选字长') { throw '标准模式整数超出 BYTE 范围时应提示错误' }
            foreach ($key in 'C1.5'.ToCharArray()) { Press-CalculatorKey $key }
            [void]$click.Invoke($programmer.FromCalculator, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch '须为整数') { throw '程序员模式不应截断标准模式的小数' }
            Press-CalculatorKey 'C'
            if (Submit-CalculatorExpression '0.999999999') { throw '未能载入接近整数的标准模式数值' }
            if ($resultLabel.Text -ne '1') { throw '验收用例须在标准模式舍入为整数' }
            $previousOperand = $programmer.Left.Text
            [void]$click.Invoke($programmer.FromCalculator, @([EventArgs]::Empty))
            if ($programmer.Result.Text -notmatch '须为整数' -or $programmer.Left.Text -ne $previousOperand) {
                throw '程序员模式不应把舍入后看似整数的标准模式小数带入'
            }
            foreach ($key in 'C1.00~'.ToCharArray()) { Press-CalculatorKey $key }
            [void]$click.Invoke($programmer.FromCalculator, @([EventArgs]::Empty))
            if ($programmer.Left.Text -ne 'FF' -or $programmer.Base.SelectedItem -ne '16') {
                throw '标准模式整数未按所选进制和字长带入'
            }
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            if (!$programmer.ToCalculator.Enabled -or $programmer.Result.Lines[2] -ne 'SIGNED  -1') { throw '有效的有符号结果无法转入' }
            $programmer.Left.Text = 'FE'
            if ($programmer.ToCalculator.Enabled) { throw '修改操作数后仍可转入旧结果' }
            $programmer.Left.Text = 'FF'
            [void]$click.Invoke($programmer.Submit, @([EventArgs]::Empty))
            foreach ($key in 'C2+'.ToCharArray()) { Press-CalculatorKey $key }
            [void]$click.Invoke($programmer.ToCalculator, @([EventArgs]::Empty))
            Press-CalculatorKey '='
            if ($resultLabel.Text -ne '1') { throw '程序员模式的有符号结果未接入标准算式' }
        } finally {
            $programmer.Window.Dispose()
        }
        $unsignedProgrammer = New-ProgrammerDialog
        try {
            $unsignedProgrammer.Width.SelectedItem = 'BYTE'
            $unsignedProgrammer.Left.Text = 'FF'
            [void]$click.Invoke($unsignedProgrammer.Submit, @([EventArgs]::Empty))
            foreach ($key in 'C2+'.ToCharArray()) { Press-CalculatorKey $key }
            [void]$click.Invoke($unsignedProgrammer.UnsignedToCalculator, @([EventArgs]::Empty))
            Press-CalculatorKey '='
            if ($resultLabel.Text -ne '257') { throw '无符号结果未接入标准算式' }
        } finally { $unsignedProgrammer.Window.Dispose() }
        foreach ($key in 'C1234.50'.ToCharArray()) { Press-CalculatorKey $key }
        $converter = New-ConverterDialog
        try {
            if ($resultLabel.Text -ne '1,234.50' -or $converter.Input.Text -ne '1234.50') {
                throw '打开单位换算时未正确带入标准模式数值'
            }
            $converter.From.SelectedItem = '英里'
            $converter.To.SelectedItem = '千米'
            $converter.Input.Text = '1'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '1.609344 千米') { throw "长度换算失败：$($converter.Result.Text)" }
            $converter.Category.SelectedItem = '温度'
            $converter.To.SelectedItem = '摄氏度'
            $converter.Input.Text = '-40'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '-40 摄氏度') { throw "温度换算失败：$($converter.Result.Text)" }
            $converter.Category.SelectedItem = '质量'
            $converter.From.SelectedItem = '盎司'
            $converter.To.SelectedItem = '克'
            $converter.Input.Text = '1'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '28.34952313 克') { throw "质量换算失败：$($converter.Result.Text)" }
            $converter.Category.SelectedItem = '速度'
            $converter.From.SelectedItem = '节'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '1.852 千米/小时') { throw "速度换算失败：$($converter.Result.Text)" }
            $converter.Input.Text = '1..2'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -notmatch '换算错误') { throw '无效小数应显示换算错误' }
            $converter.Category.SelectedItem = '时间'
            $converter.From.SelectedItem = '天'
            $converter.To.SelectedItem = '小时'
            $converter.Input.Text = '1.5'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '36 小时') { throw '时间换算失败' }
            $converter.Category.SelectedItem = '数据容量'
            $converter.From.SelectedItem = 'KiB'
            $converter.To.SelectedItem = '字节 (B)'
            $converter.Input.Text = '1'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '1024 字节 (B)') { throw '数据容量换算失败' }
            [void]$click.Invoke($converter.Swap, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '' -or $converter.To.SelectedItem -ne 'KiB') { throw '交换单位失败' }
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '0.00097656 KiB') { throw '交换后的数据容量换算失败' }
            $converter.Category.SelectedItem = '面积'
            $converter.From.SelectedItem = '市亩'
            $converter.To.SelectedItem = '平方米'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '666.66666667 平方米') { throw '面积换算失败' }
            $converter.Category.SelectedItem = '体积'
            $converter.From.SelectedItem = '美制加仑'
            $converter.To.SelectedItem = '升'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '3.78541178 升') { throw '美制体积换算失败' }
            $converter.From.SelectedItem = '英制加仑'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '4.54609 升') { throw '英制体积换算失败' }
            $converter.Category.SelectedItem = '压力'
            $converter.From.SelectedItem = '标准大气压 (atm)'
            $converter.To.SelectedItem = '托 (Torr)'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '760 托 (Torr)') { throw '压力换算失败' }
            $converter.Category.SelectedItem = '能量'
            $converter.From.SelectedItem = '千瓦时 (kWh)'
            $converter.To.SelectedItem = '兆焦 (MJ)'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '3.6 兆焦 (MJ)') { throw '能量换算失败' }
            $converter.Category.SelectedItem = '功率'
            $converter.From.SelectedItem = '机械马力 (hp)'
            $converter.To.SelectedItem = '瓦 (W)'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '745.69987158 瓦 (W)') { throw '机械马力换算失败' }
            $converter.Category.SelectedItem = '频率'
            $converter.From.SelectedItem = '转/分钟 (RPM)'
            $converter.To.SelectedItem = '赫兹 (Hz)'
            $converter.Input.Text = '1500'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '25 赫兹 (Hz)') { throw '转速换算失败' }
            $converter.Category.SelectedItem = '角度'
            $converter.From.SelectedItem = '度 (°)'
            $converter.To.SelectedItem = '弧度 (rad)'
            $converter.Input.Text = '180'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '3.14159265 弧度 (rad)') { throw '角度换算失败' }
            $converter.To.SelectedItem = '百分度 (gon)'
            if ($converter.Result.Text -ne '') { throw '更改单位后应清除旧结果' }
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '200 百分度 (gon)') { throw '百分度换算失败' }
            $converter.Input.Text = '90'
            if ($converter.Result.Text -ne '') { throw '更改数值后应清除旧结果' }
            $converter.Category.SelectedItem = '油耗'
            $converter.To.SelectedItem = '英里/美制加仑'
            $converter.Input.Text = '8'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '29.40182292 英里/美制加仑') { throw '油耗倒数换算失败' }
            $converter.Input.Text = '0'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -notmatch '油耗需要正数') { throw '油耗零值应提示错误' }
            $converter.Category.SelectedItem = '数据容量'
            $converter.From.SelectedItem = 'KiB'
            $converter.To.SelectedItem = '字节 (B)'
            $converter.Input.Text = '1'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            [void]$click.Invoke($converter.Reverse, @([EventArgs]::Empty))
            if ($converter.Input.Text -ne '1024' -or $converter.Result.Text -ne '1 KiB') { throw '反向换算回填失败' }
            $converter.Input.Text = '2048'
            if ($converter.Reverse.Enabled) { throw '修改输入后仍可反向换算过期结果' }
            $converter.Category.SelectedItem = '网络速率'
            $converter.From.SelectedItem = 'Mbit/s'
            $converter.To.SelectedItem = 'MB/s'
            $converter.Input.Text = '100'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '12.5 MB/s') { throw '网络速率位和字节的换算失败' }
            $converter.To.SelectedItem = 'MiB/s'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '11.92092896 MiB/s') { throw '网络速率二进制前缀换算失败' }
            $converter.Input.Text = '1E2'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '11.92092896 MiB/s') { throw '换算科学计数法输入失败' }
            $converter.Category.SelectedItem = '功率'
            $converter.From.SelectedItem = '兆瓦 (MW)'
            $converter.Input.Text = '1000000000'
            $mixed = Get-ConverterComparison $converter
            if (!$mixed.Success -or $mixed.Text -notmatch '超出范围  瓦' -or
                $mixed.Text -notmatch '1000000000  兆瓦') { throw '批量换算应同时保留溢出和有效结果' }
            $comparisonDialog = New-ConverterComparisonDialog '功率' $mixed
            try {
                [void]$click.Invoke($comparisonDialog.Copy, @([EventArgs]::Empty))
                if ($copyState.Text -ne $mixed.Text -or $comparisonDialog.Copy.Text -ne '已复制') {
                    throw '批量换算复制应保留所有结果'
                }
                $comparisonDialog.Values.SelectedIndex = 0
                if ($comparisonDialog.ToCalculator.Enabled) { throw '超出范围的结果不可转入标准模式' }
                $comparisonDialog.Values.SelectedIndex = 2
                $validValue = $comparisonDialog.LastValue
                $comparisonDialog.LastValue = '2147483648'
                $previousResult = $resultLabel.Text
                [void]$click.Invoke($comparisonDialog.ToCalculator, @([EventArgs]::Empty))
                if ($comparisonDialog.Transferred -or $comparisonDialog.Window.IsDisposed -or
                    $comparisonDialog.ToCalculator.Text -ne '带入失败，重试' -or $resultLabel.Text -ne $previousResult) {
                    throw '带入失败时应保留来源窗口与原计算结果'
                }
                $comparisonDialog.LastValue = $validValue
                [void]$click.Invoke($comparisonDialog.ToCalculator, @([EventArgs]::Empty))
                if (!$comparisonDialog.Transferred -or $resultLabel.Text -ne '1,000,000,000') {
                    throw '选中的换算结果未转入标准模式'
                }
            } finally { $comparisonDialog.Window.Dispose() }
            $converter.Category.SelectedItem = '网络速率'
            $converter.From.SelectedItem = 'Mbit/s'
            $converter.Input.Text = '1E2'
            $comparison = Get-ConverterComparison $converter
            $comparisonRows = $comparison.Text -split '\r?\n'
            if (!$comparison.Success -or $comparisonRows.Count -ne 11 -or
                $comparisonRows[2] -ne '100  Mbit/s' -or $comparisonRows[6] -ne '12.5  MB/s') {
                throw '同类单位对照结果不匹配'
            }
            $converter.Auto.Checked = $true
            $converter.Input.Text = '8'
            $converter.Input.Text = '16'
            $converter.To.SelectedItem = 'MB/s'
            if (!$converter.Timer.Enabled -or $converter.Result.Text -ne '') { throw '自动换算未等待输入停止' }
            $tick = [Windows.Forms.Timer].GetMethod('OnTick', $binding)
            [void]$tick.Invoke($converter.Timer, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '2 MB/s' -or $converter.Timer.Enabled) { throw '自动换算未使用最新输入' }
            $converter.Input.Text = '32'
            $converter.Auto.Checked = $false
            [void]$tick.Invoke($converter.Timer, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '') { throw '关闭自动更新后仍执行了换算' }
            $converter.Category.SelectedItem = '加速度'
            $converter.From.SelectedItem = '标准重力 (g₀)'
            $converter.To.SelectedItem = 'm/s²'
            $converter.Input.Text = '1'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '9.80665 m/s²') { throw '加速度换算失败' }
            $converter.Category.SelectedItem = '力'
            $converter.From.SelectedItem = '磅力 (lbf)'
            $converter.To.SelectedItem = '牛顿 (N)'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '4.44822162 牛顿 (N)') { throw '磅力换算失败' }
            $converter.Category.SelectedItem = '扭矩'
            $converter.From.SelectedItem = '磅力英尺 (lbf·ft)'
            $converter.To.SelectedItem = '牛顿米 (N·m)'
            $converter.Input.Text = '1'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            if ($converter.Result.Text -ne '1.35581795 牛顿米 (N·m)') { throw '扭矩换算失败' }
            $converter.Input.Text = '2'
            if ($converter.ToCalculator.Enabled) { throw '换算输入更新后仍可转入旧结果' }
            $converter.Input.Text = '1'
            [void]$click.Invoke($converter.Submit, @([EventArgs]::Empty))
            foreach ($key in 'C2+'.ToCharArray()) { Press-CalculatorKey $key }
            [void]$click.Invoke($converter.ToCalculator, @([EventArgs]::Empty))
            Press-CalculatorKey '='
            if ($resultLabel.Text -ne '3.35581795') { throw '换算结果未成为标准模式的当前操作数' }
        } finally {
            $converter.Window.Dispose()
        }
        Press-CalculatorKey 'C'
        if (Submit-CalculatorExpression '1.1e-8') { throw '无法载入极小换算输入' }
        $preciseConverter = New-ConverterDialog
        try {
            if ($preciseConverter.Input.Text -ne '0.000000011') { throw '单位换算未带入完整值' }
            $preciseConverter.From.SelectedItem = '千米'
            $preciseConverter.To.SelectedItem = '毫米'
            [void]$click.Invoke($preciseConverter.Submit, @([EventArgs]::Empty))
            if ($preciseConverter.Result.Text -ne '0.011 毫米') { throw '单位换算丢失了第九位输入精度' }
            $preciseConverter.From.SelectedItem = '毫米'
            $preciseConverter.To.SelectedItem = '米'
            $preciseConverter.Input.Text = '0.000001'
            [void]$click.Invoke($preciseConverter.Submit, @([EventArgs]::Empty))
            if ($preciseConverter.Result.Text -ne '0.000000001 米') { throw '极小换算结果显示失败' }
            $tinyComparison = Get-ConverterComparison $preciseConverter
            if (!$tinyComparison.Success -or ($tinyComparison.Text -split '\r?\n')[2] -ne '0.000000001  米') {
                throw '全部单位丢失极小非零结果'
            }
            Press-CalculatorKey 'C'
            [void]$click.Invoke($preciseConverter.ToCalculator, @([EventArgs]::Empty))
            if ($resultLabel.Text -ne '0.000000001') { throw '极小换算结果回填失败' }
        } finally { $preciseConverter.Window.Dispose() }
        foreach ($key in 'C1000000001'.ToCharArray()) { Press-CalculatorKey $key }
        $converter = New-ConverterDialog
        try {
            if ($converter.Input.Text -ne '') { throw '超出换算输入范围的数值不应自动带入' }
        } finally { $converter.Window.Dispose() }
        $dates = New-DateDialog
        try {
            $dates.Start.Text = '2024-02-28'
            $dates.Operand.Text = '2024-03-01'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Lines[0] -ne '0 年 0 个月 2 天' -or $dates.Result.Lines[1] -ne '共 2 天') { throw '跨闰日天数计算失败' }
            $dates.Mode.SelectedItem = '加天数'
            $dates.Operand.Text = '1'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-02-29') { throw '加天数日期计算失败' }
            $dates.Mode.SelectedItem = '减天数'
            $dates.Start.Text = '0001-01-02'
            $dates.Operand.Text = '1'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '0001-01-01') { throw '减天数日期或前导零显示失败' }
            $dates.Operand.Text = '2'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -notmatch '结果超出') { throw '日期越界应显示错误' }
            $dates.Mode.SelectedItem = '加月数'
            $dates.Start.Text = '2024-01-31'
            $dates.Operand.Text = '1'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-02-29') { throw '加月数应落在闰年二月末' }
            $dates.Mode.SelectedItem = '加年数'
            $dates.Start.Text = '2024-02-29'
            $dates.Operand.Text = '1'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2025-02-28') { throw '加年数应落在平年二月末' }
            $dates.Mode.SelectedItem = '加年/月/日'
            $dates.Start.Text = '2024-01-31'
            $dates.Operand.Text = '1'
            $dates.Months.Text = '1'
            $dates.Days.Text = '1'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2025-03-01') { throw '组合日期计算失败' }
            $dates.Mode.SelectedItem = '星期与周数'
            $dates.Start.Text = '2021-01-01'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Lines[0] -ne '星期五' -or $dates.Result.Lines[1] -ne '2020 年第 53 周') {
                throw '跨年 ISO 周数验收失败'
            }
            $dates.Mode.SelectedItem = '加月数'
            $dates.Start.Text = '2024-01-31'
            $dates.Operand.Text = '1'
            $dates.MonthEnd.Checked = $true
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-02-29') { throw '月末规则未处理闰年二月' }
            [void]$click.Invoke($dates.UseResult, @([EventArgs]::Empty))
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-03-31') { throw '连续按月推算丢失月末规则' }
            $dates.MonthEnd.Checked = $false
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-03-29') { throw '关闭月末规则后未恢复普通按月计算' }
            $dates.Mode.SelectedItem = '加年数'
            $dates.Start.Text = '2023-02-28'
            $dates.Operand.Text = '1'
            $dates.MonthEnd.Checked = $true
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-02-29') { throw '按年推算未保留二月月末' }
            $dates.MonthEnd.Checked = $false
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-02-28') { throw '普通加年规则被改变' }
            $dates.Mode.SelectedItem = '按 ISO 周查日期'
            $dates.Start.Text = '2020'
            $dates.Operand.Text = '53'
            $dates.Months.Text = '5'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2021-01-01') { throw 'ISO 周未查到跨年日期' }
            [void]$click.Invoke($dates.UseResult, @([EventArgs]::Empty))
            if ($dates.Mode.SelectedItem -ne '星期与周数' -or $dates.Start.Text -ne '2021-01-01') {
                throw 'ISO 周反查日期未成为起始日期'
            }
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            [void]$click.Invoke($dates.UseResult, @([EventArgs]::Empty))
            if ($dates.Mode.SelectedItem -ne '按 ISO 周查日期' -or $dates.Start.Text -ne '2020' -or
                $dates.Operand.Text -ne '53' -or $dates.Months.Text -ne '5' -or $dates.UseResult.Enabled) {
                throw 'ISO 周结果未正确带入反查'
            }
            $dates.Mode.SelectedItem = '加周数'
            $dates.Start.Text = '2024-12-30'
            $dates.Operand.Text = '2'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2025-01-13') { throw '跨年加周数失败' }
            [void]$click.Invoke($dates.UseResult, @([EventArgs]::Empty))
            $dates.Mode.SelectedItem = '减周数'
            $dates.Operand.Text = '2'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-12-30') { throw '跨年减周数失败' }
            $dates.Mode.SelectedItem = '相隔工作日'
            $dates.Start.Text = '2024-03-01'
            $dates.Operand.Text = '2024-03-04'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '1 个工作日') { throw '跨周末工作日验收失败' }
            $dates.WorkdayExceptions.Text = '-2024-03-04'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '0 个工作日') { throw '例外休息日仍计入工作日' }
            $dates.Mode.SelectedItem = '加工作日'
            $dates.Operand.Text = '1'
            $dates.WorkdayExceptions.Text = '+2024-03-02, -2024-03-04'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-03-02') { throw '例外上班的周六未计入工作日' }
            $dates.WorkdayExceptions.Text = '+2024-03-02,-2024-03-02'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -notmatch '不可重复') { throw '重复例外日期未拒绝' }
            $reopenedDates = New-DateDialog
            try {
                $reopenedDates.Mode.SelectedItem = '减工作日'
                if ($reopenedDates.WorkdayExceptions.Text -ne '+2024-03-02, -2024-03-04') {
                    throw '无效例外覆盖了本次会话已通过验证的例外日期'
                }
                $reopenedDates.Start.Text = '2024-03-05'
                $reopenedDates.Operand.Text = '1'
                [void]$click.Invoke($reopenedDates.Submit, @([EventArgs]::Empty))
                if ($reopenedDates.Result.Text -ne '2024-03-02') { throw '重开日期窗口后例外未生效' }
            } finally { $reopenedDates.Window.Dispose() }
            $dates.WorkdayExceptions.Clear()
            $dates.Mode.SelectedItem = '加工作日'
            $dates.Start.Text = '2024-03-01'
            $dates.Operand.Text = '1'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-03-04') { throw '添加工作日未跳过周末' }
            [void]$click.Invoke($dates.UseResult, @([EventArgs]::Empty))
            if ($dates.Start.Text -ne '2024-03-04' -or $dates.Operand.Text -ne '1' -or $dates.UseResult.Enabled) {
                throw '日期结果未回填或改变了工作日数量'
            }
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-03-05') { throw '回填后未能连续计算日期' }
            $dates.Operand.Text = '2'
            if ($dates.UseResult.Enabled -or $dates.Result.Text -ne '') { throw '日期输入修改后仍保留旧结果' }
            $dates.Mode.SelectedItem = '减工作日'
            $dates.Start.Text = '2024-03-03'
            $dates.Operand.Text = '1'
            [void]$click.Invoke($dates.Submit, @([EventArgs]::Empty))
            if ($dates.Result.Text -ne '2024-03-01') { throw '从星期日回退工作日失败' }
            $picker = New-CalculatorDatePicker $dates.Start
            try {
                if ($picker.Calendar.SelectionStart -ne [DateTime]::new(2024, 3, 3)) { throw '日历未定位到当前输入日期' }
                $picker.Calendar.SetDate([DateTime]::new(2024, 2, 29))
                [void]$click.Invoke($picker.Select, @([EventArgs]::Empty))
                if ($dates.Start.Text -ne '2024-02-29' -or $dates.Result.Text -ne '') { throw '日历选定没有更新输入' }
            } finally { $picker.Window.Dispose() }
        } finally {
            $dates.Window.Dispose()
        }
        Press-CalculatorKey 'C'
        if (Submit-CalculatorExpression '0.000000011') { throw '无法载入科学计算的精度验收值' }
        if ($resultLabel.Text -ne '0.00000001') { throw '标准模式显示须与内部值存在精度差异' }
        $science = New-ScientificDialog
        try {
            if ($science.Value.Text -ne '0.000000011') { throw '科学计算未带入标准模式完整值' }
            $science.Mode.SelectedItem = '常用对数 log₁₀'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '-7.958607315') { throw "科学计算未使用完整值：$($science.Result.Text)" }
            $science.Mode.SelectedIndex = 0
            $science.Value.Text = '2'
            $science.Exponent.Text = '-3'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.125') { throw '负整数次幂验收失败' }
            $science.Value.Text = '9'
            $science.Exponent.Text = '0.5'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '3') { throw '小数次幂验收失败' }
            $science.Value.Text = '10'
            $science.Exponent.Text = '-9'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.000000001' -or !$science.ToCalculator.Enabled) {
                throw '极小幂结果应保留完整精度并可带入'
            }
            $science.Mode.SelectedItem = '阶乘'
            $science.Value.Text = '20'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '2432902008176640000') { throw '阶乘验收失败' }
            if ($science.ToCalculator.Enabled) { throw '超大阶乘不应转入标准模式' }
            $science.Value.Text = '21'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -notmatch '阶乘需要') { throw '阶乘越界提示验收失败' }
            $science.Mode.SelectedItem = '正弦 sin'
            $science.Value.Text = '30'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.5') { throw '角度正弦验收失败' }
            $science.Unit.SelectedIndex = 1
            $science.Value.Text = '1'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.841470985') { throw '弧度正弦验收失败' }
            $science.Value.Text = '1e-9'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.000000001' -or !$science.ToCalculator.Enabled) {
                throw '小角度的正弦应保留第九位并可带入标准模式'
            }
            $science.Mode.SelectedItem = '自然对数 ln'
            $science.Value.Text = '2'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.693147181') { throw '自然对数验收失败' }
            $science.Value.Text = '1.000000001'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.000000001' -or !$science.ToCalculator.Enabled) {
                throw '接近 1 的自然对数应保留第九位'
            }
            $science.Mode.SelectedItem = '常用对数 log₁₀'
            $science.Value.Text = '0.001'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '-3') { throw '常用对数验收失败' }
            $science.Mode.SelectedItem = '反正弦 asin'
            $science.Unit.SelectedIndex = 0
            $science.Value.Text = '0.5'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '30') { throw '反正弦角度验收失败' }
            $science.Mode.SelectedItem = '反正切 atan'
            $science.Unit.SelectedIndex = 1
            $science.Value.Text = '-1'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '-0.785398163') { throw '反正切弧度验收失败' }
            $science.Unit.SelectedItem = '百分度 (GRAD)'
            $science.Value.Text = '1'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '50') { throw '反正切百分度验收失败' }
            $science.Mode.SelectedItem = '正切 tan'
            $science.Value.Text = '100'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -notmatch '正切未定义') { throw '百分度直角应拒绝计算正切' }
            $science.Mode.SelectedItem = '自然指数 eˣ'
            $science.Value.Text = '1'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '2.718281828') { throw '自然指数验收失败' }
            $science.Mode.SelectedItem = '十进制指数 10ˣ'
            $science.Value.Text = '0.5'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '3.16227766') { throw '十进制指数验收失败' }
            $science.Value.Text = '-9'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.000000001') { throw '十进制指数与幂运算精度不一致' }
            $science.Mode.SelectedItem = '正弦 sin'
            $science.Unit.SelectedIndex = 0
            $science.Value.Text = '30'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            [void]$click.Invoke($science.UseResult, @([EventArgs]::Empty))
            if ($science.Value.Text -ne '0.5' -or $science.UseResult.Enabled) { throw '科学计算结果回填失败' }
            $science.Mode.SelectedItem = '反正弦 asin'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '30') { throw '科学计算无法连续运算' }
            $science.Value.Text = '2'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.UseResult.Enabled) { throw '错误结果不应允许回填' }
            $science.Mode.SelectedItem = '整数次方根'
            $science.Value.Text = '-27'
            $science.Exponent.Text = '3'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '-3') { throw '负数开奇次方验收失败' }
            $science.Exponent.Text = '2'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -notmatch '负数不能开偶次方') { throw '负数开偶次方未提示错误' }
            $science.Mode.SelectedItem = '任意底数对数'
            $science.Value.Text = '8'
            $science.Exponent.Text = '0.5'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '-3') { throw '任意底数对数验收失败' }
            $science.Value.Text = '3'
            $science.Exponent.Text = '2'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '1.584962501' -or !$science.ToCalculator.Enabled) {
                throw '任意底数对数应保留九位并可带入标准模式'
            }
            $science.Exponent.Text = '1'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -notmatch '对数底数') { throw '底数 1 应提示错误' }
            $science.Mode.SelectedItem = '取余 mod'
            $science.Value.Text = '-7.5'
            $science.Exponent.Text = '2'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '-1.5') { throw '小数取余验收失败' }
            [void]$click.Invoke($science.UseResult, @([EventArgs]::Empty))
            $science.Mode.SelectedItem = '绝对值 abs'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '1.5') { throw '绝对值验收失败' }
            $science.Value.Text = '-1.000000001'
            $science.Mode.SelectedItem = '向下取整 floor'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '-2') { throw '向下取整失败' }
            $science.Mode.SelectedItem = '向上取整 ceil'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '-1') { throw '向上取整失败' }
            $science.Mode.SelectedItem = '双曲正弦 sinh'
            $science.Value.Text = '-1'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '-1.175201194') { throw '双曲正弦验收失败' }
            $science.Mode.SelectedItem = '双曲正切 tanh'
            $science.Value.Text = '100'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '1') { throw '双曲正切大数验收失败' }
            $science.Value.Text = '10'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.999999996') { throw '双曲正切过早舍入为 1' }
            $science.Mode.SelectedItem = '常用对数 log₁₀'
            $science.Value.Text = '1E-9'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '-9') { throw '科学计数法输入失败' }
            $science.Value.Text = '1e-10'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.UseResult.Enabled -or $science.Result.Text -notmatch '定点数值') {
                throw '超出定点精度的科学计数法应提示错误'
            }
            $science.Mode.SelectedItem = '整数次方根'
            $science.Mode.SelectedItem = '绝对值 abs'
            $science.Value.Text = '-1e-9'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.000000001' -or !$science.ToCalculator.Enabled) {
                throw '极小绝对值应保留完整精度并可带入'
            }
            $science.Mode.SelectedItem = '取余 mod'
            $science.Value.Text = '1.000000001'
            $science.Exponent.Text = '1'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.000000001') { throw '科学取余丢失保护位' }
            $science.Mode.SelectedItem = '倒数 1/x'
            $science.Value.Text = '0'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.ToCalculator.Enabled -or $science.Result.Text -notmatch '不能除以零') {
                throw '科学倒数应拒绝零'
            }
            $science.Value.Text = '1000000000'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            if ($science.Result.Text -ne '0.000000001' -or !$science.ToCalculator.Enabled) {
                throw '极小倒数应保留九位并可带入'
            }
            $science.Mode.SelectedItem = '整数次方根'
            $science.Value.Text = '2'
            $science.Exponent.Text = '2'
            [void]$click.Invoke($science.Submit, @([EventArgs]::Empty))
            foreach ($key in 'C1000000000*'.ToCharArray()) { Press-CalculatorKey $key }
            [void]$click.Invoke($science.ToCalculator, @([EventArgs]::Empty))
            Press-CalculatorKey '='
            if ($resultLabel.Text -ne '1,414,213,562') { throw '科学结果未成为标准模式的当前操作数' }
        } finally {
            $science.Window.Dispose()
        }
        foreach ($key in 'C2+'.ToCharArray()) { Press-CalculatorKey ([string]$key) }
        $pasteArgs = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::V)
        $copyState.Input = ' −.125 '
        [void]$keydown.Invoke($form, @($pasteArgs))
        if ($resultLabel.Text -ne '-0.125') { throw 'Ctrl+V 未装入数值' }
        $copyState.Input = '3+4'
        [void]$keydown.Invoke($form, @($pasteArgs))
        if ($resultLabel.Text -ne '-0.125') { throw '拒绝非数字时更改了操作数' }
        $copyState.Input = '2147483648'
        [void]$keydown.Invoke($form, @($pasteArgs))
        if ($resultLabel.Text -ne '-0.125' -or $expressionLabel.Text -notmatch '超出') {
            throw '越界粘贴没有保留操作数或显示提示'
        }
        Press-CalculatorKey '='
        if ($resultLabel.Text -ne '1.875') { throw '粘贴未保留待完成的运算' }
        foreach ($key in 'C2/0+'.ToCharArray()) { Press-CalculatorKey $key }
        $copyState.Input = '5'
        [void]$keydown.Invoke($form, @($pasteArgs))
        foreach ($key in '+2='.ToCharArray()) { Press-CalculatorKey $key }
        if ($resultLabel.Text -ne '7') { throw '除零后粘贴未重新开始计算' }
        foreach ($key in 'C1/0=*5+2='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        if ($resultLabel.Text -ne '7') { throw '除零后直接输入数字未重新开始计算' }
        foreach ($key in '2147483647*2=.5*4='.ToCharArray()) {
            [void]$keypress.Invoke($form, @([Windows.Forms.KeyPressEventArgs]::new($key)))
        }
        if ($resultLabel.Text -ne '2') { throw '溢出后直接输入小数点未重新开始计算' }
        Press-CalculatorKey 'C'
        $editKeys = @('~', '.', '0', 'B', 'B', '=')
        $editDisplays = @('-0', '-0.', '-0.0', '-0.', '-0', '0')
        for ($i = 0; $i -lt $editKeys.Count; $i++) {
            Press-CalculatorKey $editKeys[$i]
            if ($resultLabel.Text -ne $editDisplays[$i]) { throw "小数编辑显示失败：$($editKeys[$i])" }
        }
        $copyState.Input = '1,234.50'
        [void]$keydown.Invoke($form, @($pasteArgs))
        if ($resultLabel.Text -ne '1,234.50') { throw '千位分组粘贴失败' }
        $copyState.Input = '12,34.50'
        [void]$keydown.Invoke($form, @($pasteArgs))
        if ($resultLabel.Text -ne '1,234.50' -or $expressionLabel.Text -ne '请粘贴单个有效数字') {
            throw '错误千位分组改变了输入'
        }
        Copy-CalculatorResult
        if ($copyState.Text -ne '1,234.50') { throw '复制丢失千位分隔或小数末尾的零' }
        Press-CalculatorKey 'C'
        $copyState.Input = $copyState.Text
        [void]$keydown.Invoke($form, @($pasteArgs))
        foreach ($key in '+.5='.ToCharArray()) { Press-CalculatorKey $key }
        if ($resultLabel.Text -ne '1,235') { throw '分组数字复制和粘贴后无法继续计算' }
        $copyState.Input = '-2,147,483,646.99999999'
        [void]$keydown.Invoke($form, @($pasteArgs))
        Switch-CalculatorCompactView
        if ($resultLabel.Text -ne $copyState.Input -or
            [Windows.Forms.TextRenderer]::MeasureText($resultLabel.Text, $resultLabel.Font).Width -gt $resultLabel.ClientSize.Width) {
            throw '紧凑视图无法完整显示大数'
        }
        Switch-CalculatorCompactView
        foreach ($key in 'C2+'.ToCharArray()) { Press-CalculatorKey $key }
        $copyState.Input = '1.25E+3'
        [void]$keydown.Invoke($form, @($pasteArgs))
        if ($resultLabel.Text -ne '1,250') { throw '科学计数法粘贴失败' }
        $copyState.Input = '1e-10'
        [void]$keydown.Invoke($form, @($pasteArgs))
        if ($resultLabel.Text -ne '1,250' -or $expressionLabel.Text -ne '请粘贴单个有效数字') {
            throw '超出小数输入精度的科学计数法未拒绝'
        }
        Press-CalculatorKey '='
        if ($resultLabel.Text -ne '1,252') { throw '粘贴科学计数法未保留待完成运算' }
        Press-CalculatorKey 'C'
        foreach ($key in '1000000000*'.ToCharArray()) { Press-CalculatorKey ([string]$key) }
        $copyState.Input = '1e-9'
        [void]$keydown.Invoke($form, @($pasteArgs))
        if ($resultLabel.Text -ne '0.000000001') { throw '非零的九位操作数不应显示为零' }
        Press-CalculatorKey '='
        if ($resultLabel.Text -ne '1') { throw '九位科学计数法未保留内部值或待运算' }
        Press-CalculatorKey 'C'
        foreach ($key in '1/1000000000=~'.ToCharArray()) { Press-CalculatorKey ([string]$key) }
        if ($resultLabel.Text -ne '-0.000000001' -or $historyList.Items[0].Result -ne '0.000000001') {
            throw '极小非零结果应在显示与历史中保留'
        }
        Copy-CalculatorResult
        if ($copyState.Text -ne '-0.000000001') { throw '普通复制不应将非零结果复制为零' }
        Press-CalculatorKey '*'
        if ($expressionLabel.Text -ne '-0.000000001 ×') { throw '待运算表达式丢失左操作数的保护位' }
        foreach ($key in '1000000000='.ToCharArray()) { Press-CalculatorKey ([string]$key) }
        if ($resultLabel.Text -ne '-1') { throw '极小左操作数无法继续计算' }
        Press-CalculatorKey 'C'
        $copyState.Input = '1e-9'
        [void]$keydown.Invoke($form, @($pasteArgs))
        Press-CalculatorKey 'M'
        [void]$dropDown.Invoke($memorySlot, @([EventArgs]::Empty))
        if ($memorySlot.Items[$memorySlot.SelectedIndex] -notmatch '  0\.000000001$') {
            throw '记忆预览丢失极小非零值'
        }
        Press-CalculatorKey 'C'
        Press-CalculatorKey 'G'
        if ($resultLabel.Text -ne '0.000000001') { throw '记忆预览与取出结果不一致' }
        Press-CalculatorKey 'X'
        $copyState.Input = '12.340'
        [void]$keydown.Invoke($form, @($pasteArgs))
        if ($resultLabel.Text -ne '12.340') { throw '粘贴时丢失末尾的零' }
        Press-CalculatorKey 'B'
        Press-CalculatorKey '5'
        if ($resultLabel.Text -ne '12.345') { throw '粘贴后退格或追加小数失败' }
        $expressionPaste = [Windows.Forms.KeyEventArgs]::new(
            [Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Shift -bor [Windows.Forms.Keys]::V)
        foreach ($key in 'C5+'.ToCharArray()) { Press-CalculatorKey $key }
        $copyState.Input = '2 × (3 + 4)'
        [void]$keydown.Invoke($form, @($expressionPaste))
        if (!$expressionPaste.SuppressKeyPress -or $resultLabel.Text -ne '14') { throw '算式粘贴未交由白泽求值' }
        $pasteHistoryCount = $historyList.Items.Count
        $copyState.Input = '1 ÷ 0'
        [void]$keydown.Invoke($form, @($expressionPaste))
        if ($resultLabel.Text -ne '14' -or $expressionLabel.Text -notmatch '不能除以零' -or
            $historyList.Items.Count -ne $pasteHistoryCount) {
            throw '无效算式粘贴更改了待计算状态'
        }
        Press-CalculatorKey '='
        if ($resultLabel.Text -ne '19') { throw '粘贴算式结果未接入当前运算' }
        $copyState.Input = '1 ÷ 3'
        [void]$keydown.Invoke($form, @($expressionPaste))
        $savedPaste = @(Read-CalculatorHistory)[0]
        if ($savedPaste.Expression -ne '1 ÷ 3' -or $savedPaste.Result -ne '0.33333333' -or
            $savedPaste.InternalValue -ne 333333333L) { throw '粘贴算式未连同内部值写入历史' }
        Press-CalculatorKey 'C'
        $historyList.SelectedIndex = 0
        Restore-CalculatorHistory
        foreach ($key in '*3='.ToCharArray()) { Press-CalculatorKey $key }
        if ($resultLabel.Text -ne '1') { throw '粘贴算式丢失了标准模式的内部保护位' }
        Press-CalculatorKey 'C'
        foreach ($key in '1/6='.ToCharArray()) { Press-CalculatorKey ([string]$key) }
        Copy-CalculatorResult
        if ($copyState.Text -ne '0.16666667') { throw '普通复制应保留显示精度' }
        $precisionCopy = [Windows.Forms.KeyEventArgs]::new(
            [Windows.Forms.Keys]::Control -bor [Windows.Forms.Keys]::Shift -bor [Windows.Forms.Keys]::C)
        [void]$keydown.Invoke($form, @($precisionCopy))
        if (!$precisionCopy.SuppressKeyPress -or $copyState.Text -ne '0.166666666') {
            throw '完整精度复制未保留内部值'
        }
        Press-CalculatorKey 'C'
        $copyState.Input = $copyState.Text
        [void]$keydown.Invoke($form, @($pasteArgs))
        foreach ($key in '*6='.ToCharArray()) { Press-CalculatorKey ([string]$key) }
        if ($resultLabel.Text -ne '1') { throw '完整精度复制粘贴往返失去保护位' }
        $copyState.Input = ('1+' * 70) + '1'
        [void]$keydown.Invoke($form, @($expressionPaste))
        $savedPaste = @(Read-CalculatorHistory)[0]
        if ($savedPaste.Expression -ne $copyState.Input -or $savedPaste.Result -ne '71') {
            throw '长粘贴算式的历史记录无法完整读回'
        }
        $historyList.SelectedIndex = 0
        [void]$click.Invoke($historyCopy, @([EventArgs]::Empty))
        if ($copyState.Text -ne $savedPaste.Expression) { throw '复制历史算式时发生截断' }
        Press-CalculatorKey 'C'
        $copyState.Input = $copyState.Text
        [void]$keydown.Invoke($form, @($expressionPaste))
        if ($resultLabel.Text -ne '71') { throw '复制的历史算式无法重新求值' }
        foreach ($key in 'C1000+2='.ToCharArray()) { Press-CalculatorKey $key }
        $historyList.SelectedIndex = 0
        [void]$click.Invoke($historyCopy, @([EventArgs]::Empty))
        if ($copyState.Text -ne '1,000 + 2') { throw '历史算式复制丢失千位分组' }
        Press-CalculatorKey 'C'
        $copyState.Input = $copyState.Text
        [void]$keydown.Invoke($form, @($expressionPaste))
        if ($resultLabel.Text -ne '1,002') { throw '含千位分组的历史算式无法重新求值' }
        $copyState.Input = '10,00 + 2'
        [void]$keydown.Invoke($form, @($expressionPaste))
        if ($resultLabel.Text -ne '1,002') { throw '无效的千位分组被求值' }
        $copyState.Input = '√(81) + (3)² + 1E-1'
        [void]$keydown.Invoke($form, @($expressionPaste))
        if ($resultLabel.Text -ne '18.1') { throw '平方根、平方或科学计数法的粘贴求值失败' }
        $copyState.Input = '2π + 2(3+4)'
        [void]$keydown.Invoke($form, @($expressionPaste))
        if ($resultLabel.Text -ne '20.28318531') { throw '省略乘号或圆周率符号求值失败' }
        $copyState.Input = '√(-1)'
        [void]$keydown.Invoke($form, @($expressionPaste))
        if ($resultLabel.Text -ne '20.28318531' -or $expressionLabel.Text -notmatch '负数不能开平方根') {
            throw '负数平方根粘贴未保留当前结果'
        }
        foreach ($key in 'Cj12MCk3MCj7+'.ToCharArray()) { Press-CalculatorKey $key }
        $historyList.SelectedIndex = 0
        $textResult = Invoke-CalculatorCommand '"-1/8" --expr-text'
        if (!$textResult.Success -or $textResult.Text -ne '-0.125') { throw 'Windows 十进制文本输出失败' }
        $tinyTextResult = Invoke-CalculatorCommand '"-1/1000000000" --expr-text'
        if (!$tinyTextResult.Success -or $tinyTextResult.Text -ne '-0.000000001') { throw 'Windows 极小值文本输出失败' }
        $originalEntry = $historyList.SelectedItem
        if ($expressionButton.Bounds.IntersectsWith($memorySlot.Bounds) -or
            !$form.ClientRectangle.Contains($expressionButton.Bounds)) {
            throw '输入算式按钮被记忆槽遮挡或超出窗口'
        }
        $expressionDialog = New-CalculatorExpressionDialog $originalEntry.Expression
        try {
            if (!$historyEdit.Enabled -or $expressionDialog.Input.Text -ne $originalEntry.Expression) {
                throw '编辑窗口未带入所选历史算式'
            }
            $expressionDialog.Input.Text = '  √(9)+1,000+*3'
            [void]$click.Invoke($expressionDialog.Submit, @([EventArgs]::Empty))
            if ($expressionDialog.Input.SelectedText -ne '*' -or
                $expressionDialog.Input.SelectionStart -ne $expressionDialog.Input.Text.IndexOf('*')) {
                throw '编辑窗口未将错误位置映射到原始输入'
            }
            $expressionDialog.Input.Text = '1/0'
            [void]$click.Invoke($expressionDialog.Submit, @([EventArgs]::Empty))
            if ($expressionDialog.Status.Text -notmatch '不能除以零' -or $expressionDialog.Input.Text -ne '1/0' -or
                $expressionDialog.Window.DialogResult -ne [Windows.Forms.DialogResult]::None) {
                throw '无效算式未留在编辑窗口中'
            }
            $expressionDialog.Input.Text = '2(3+4)'
            $beforePreview = $historyList.Items.Count
            [void]$click.Invoke($expressionDialog.Preview, @([EventArgs]::Empty))
            if ($expressionDialog.Status.Text -ne '预览结果 14' -or $resultLabel.Text -ne '7' -or
                $historyList.Items.Count -ne $beforePreview -or $expressionDialog.Window.DialogResult -ne 'None') {
                throw '预览改变了当前运算、历史或窗口状态'
            }
            $expressionDialog.Input.Text = 'ans*2'
            [void]$click.Invoke($expressionDialog.Preview, @([EventArgs]::Empty))
            if ($expressionDialog.Status.Text -ne '预览结果 14' -or $resultLabel.Text -ne '7') {
                throw '预览未使用标准模式的当前值'
            }
            $expressionDialog.Input.Text = 'm1+m2'
            [void]$click.Invoke($expressionDialog.Preview, @([EventArgs]::Empty))
            if ($expressionDialog.Status.Text -ne '预览结果 15' -or $resultLabel.Text -ne '7') {
                throw '无法在算式中读取多个记忆寄存器'
            }
            $expressionDialog.AutoPreview.Checked = $true
            $expressionDialog.Input.Text = '1+*2'
            $expressionDialog.Input.Select(0, 0)
            if (!$expressionDialog.Timer.Enabled) { throw '修改输入后未安排自动预览' }
            [void]$tick.Invoke($expressionDialog.Timer, @([EventArgs]::Empty))
            if ($expressionDialog.Status.Text -notmatch '无效算式' -or $expressionDialog.Input.SelectionStart -ne 0) {
                throw '自动预览错误移动了编辑光标'
            }
            $expressionDialog.Input.Text = '2(3+4)'
            [void]$tick.Invoke($expressionDialog.Timer, @([EventArgs]::Empty))
            if ($expressionDialog.Status.Text -ne '预览结果 14' -or $expressionDialog.Timer.Enabled -or
                $resultLabel.Text -ne '7' -or $historyList.Items.Count -ne $beforePreview) {
                throw '自动预览未正确求值或改变了当前运算'
            }
            [void]$click.Invoke($expressionDialog.Submit, @([EventArgs]::Empty))
            Press-CalculatorKey '='
            if ($expressionDialog.Window.DialogResult -ne [Windows.Forms.DialogResult]::OK -or $resultLabel.Text -ne '21') {
                throw '编辑后的算式未接入标准模式'
            }
            if ($historyList.Items[1].Expression -ne '2(3+4)' -or !$historyList.Items.Contains($originalEntry)) {
                throw '历史算式修改后未新增记录或覆盖了原记录'
            }
        } finally { $expressionDialog.Window.Dispose() }
        $segment = @(Get-ClippedGraphSegment 0 101 -1000 10 50)
        if ($segment.Count -ne 2 -or [math]::Abs($segment[0].X - 99.9) -gt .001 -or
            [math]::Abs($segment[1].X - 100.1) -gt .001 -or $segment[0].Y -ne 100 -or $segment[1].Y -ne 0) {
            throw '跨越纵轴边界的线段裁剪改变了斜率'
        }
        if (@(Get-ClippedGraphSegment 0 101 2 3 50).Count -ne 0) { throw '视图外的线段仍会绘制' }
        $normalTicks = @(Get-GraphTicks (-10d) (10d) 8)
        $smallTicks = @(Get-GraphTicks (0d) (0.0000002d) 8)
        if (($normalTicks -join ',') -ne '-10,-5,0,5,10' -or $smallTicks.Count -ne 5 -or
            $smallTicks[1] -ne 0.00000005d) { throw '绘图自动刻度计算失败' }
        $graph = New-GraphDialog
        try {
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($graph.Canvas.Tag.Series[0].Samples[0] -ne 100000000000L -or $graph.Canvas.Tag.Series[0].Samples[100] -ne 0) {
                throw '抛物线采样失败'
            }
            $graph.Minimum.Text = '-8'
            if ($null -ne $graph.Canvas.Tag -or $graph.Export.Enabled -or $graph.Evaluate.Enabled -or
                $graph.Roots.Enabled -or $graph.CopyIntersections.Enabled -or $graph.Status.Text -notmatch '重新绘制') {
                throw '横轴范围修改后仍使用旧采样'
            }
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($graph.Canvas.Tag.Minimum -ne -8) { throw '重绘未采用新的横轴范围' }
            $graph.Density.SelectedItem = '401'
            if ($null -ne $graph.Canvas.Tag -or $graph.Export.Enabled) { throw '更改密度后仍使用旧采样' }
            $graph.Density.SelectedItem = '201'
            $graph.Expression.Text = 'x'
            $graph.Minimum.Text = '0'
            $graph.Maximum.Text = '0.000000201'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $data = $graph.Canvas.Tag
            if ($data.SampleOffsets[100] -ne 100 -or $data.SampleOffsets[200] -ne 201 -or
                (Get-GraphSampleX $data 100) -ne '0.0000001' -or (Find-GraphSampleIndex $data .5012) -ne 101) {
                throw '窄区间采样坐标与光标不一致'
            }
            $graph.Minimum.Text = '-10'
            $graph.Maximum.Text = '10'
            $graph.Expression.Text = '1/(x-.05); tan(x); 1000*(x-.05); 1/(x-.05)^2'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $links = $graph.Canvas.Tag.Series
            if ($links[0].Links[101] -or $links[1].Links[116] -or !$links[2].Links[101] -or $links[3].Links[101]) {
                throw '渐近线断开或陡峭零点连线错误'
            }
            $graph.Expression.Text = '1/(x-.025)^2; 1/(.001+(x-.025)^2)'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $links = $graph.Canvas.Tag.Series
            if ($links[0].Links[101] -or !$links[1].Links[101]) { throw '偏离中点的极点或连续尖峰判断错误' }
            $graph.Expression.Text = 'asin(x); log10(x); log2(x); cbrt(x)'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $samples = $graph.Canvas.Tag.Series
            if ($samples[0].Samples[0] -ne [long]::MaxValue -or $samples[0].Samples[100] -ne 0 -or
                $samples[1].Samples[100] -ne [long]::MaxValue -or $samples[1].Samples[110] -ne 0 -or
                $samples[2].Samples[120] -ne 1000000000 -or
                $samples[3].Samples[20] -ne -2000000000 -or $samples[3].Samples[180] -ne 2000000000) {
                throw '反正弦或常用对数的绘图定义域错误'
            }
            $graph.Expression.Text = '-x^2'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($graph.Canvas.Tag.Series[0].Samples[0] -ne -100000000000L) { throw '绘图符号优先级错误' }
            $graph.Expression.Text = '(-x)^2'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($graph.Canvas.Tag.Series[0].Samples[0] -ne 100000000000L) { throw '绘图括号优先级错误' }
            $graph.Expression.Text = 'sqrt(abs(x))'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($graph.Canvas.Tag.Series[0].Samples[0] -ne 3162277660L -or $graph.Canvas.Tag.Series[0].Samples[100] -ne 0) {
                throw '绘图嵌套函数采样失败'
            }
            $graph.Expression.Text = '1/x'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($graph.Canvas.Tag.Series[0].Samples[99] -ne -10000000000L -or
                $graph.Canvas.Tag.Series[0].Samples[100] -ne [long]::MaxValue -or
                $graph.Canvas.Tag.Series[0].Samples[101] -ne 10000000000L) { throw '不连续采样失败' }
            $bitmap = [Drawing.Bitmap]::new($graph.Canvas.Width, $graph.Canvas.Height)
            try {
                $graph.Canvas.DrawToBitmap($bitmap, $graph.Canvas.ClientRectangle)
                $gold = [Drawing.ColorTranslator]::FromHtml('#F1C56C').ToArgb()
                $hasCurve = $false
                for ($x = 0; $x -lt 80 -and !$hasCurve; $x++) {
                    for ($y = 163; $y -lt 180 -and !$hasCurve; $y++) {
                        $hasCurve = $bitmap.GetPixel($x, $y).ToArgb() -eq $gold
                    }
                }
                if (!$hasCurve) { throw '绘图画布没有渲染曲线' }
            } finally { $bitmap.Dispose() }
            $graph.Expression.Text = 'x; -x; sqrt(x)'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $series = $graph.Canvas.Tag.Series
            if ($series.Count -ne 3 -or $series[0].Samples[0] -ne -10000000000L -or
                $series[1].Samples[0] -ne 10000000000L -or $series[2].Samples[0] -ne [long]::MaxValue -or
                $series[0].Color -eq $series[1].Color -or $graph.Legend[2].Text -ne 'sqrt(x)') {
                throw '多曲线采样或图例错误'
            }
            $csvPath = Join-Path ([IO.Path]::GetTempPath()) ('BaizeGraph-' + [Guid]::NewGuid() + '.csv')
            try {
                if (!$graph.Export.Enabled) { throw '绘图后无法导出' }
                Export-CalculatorGraph $graph.Canvas.Tag $csvPath
                $rows = [IO.File]::ReadAllLines($csvPath)
                if ($rows.Count -ne 202 -or $rows[0] -ne 'x,y1,y2,y3' -or
                    $rows[1] -ne '-10,-10,10,' -or $rows[101] -ne '0,0,0,0' -or
                    $rows[201] -ne '10,10,-10,3.16227766') { throw '多曲线 CSV 内容不匹配' }
            } finally { [IO.File]::Delete($csvPath) }
            $pngPath = Join-Path ([IO.Path]::GetTempPath()) ('BaizeGraph-' + [Guid]::NewGuid() + '.png')
            try {
                $graph.Canvas.Tag.Cursor = 100
                Export-CalculatorGraphImage $graph $pngPath
                $snapshot = [Drawing.Image]::FromFile($pngPath)
                try {
                    if ($snapshot.RawFormat.Guid -ne [Drawing.Imaging.ImageFormat]::Png.Guid -or
                        $snapshot.Width -ne $graph.Canvas.Width -or $snapshot.Height -ne $graph.Canvas.Height + 90 -or
                        $graph.Canvas.Tag.Cursor -ne 100) { throw '多曲线 PNG 格式、图例高度或光标状态错误' }
                } finally { $snapshot.Dispose() }
                $graph.Canvas.Tag.Cursor = -1
            } finally { [IO.File]::Delete($pngPath) }
            $mouseMove = [Windows.Forms.Control].GetMethod('OnMouseMove', $binding)
            $mouseLeave = [Windows.Forms.Control].GetMethod('OnMouseLeave', $binding)
            $center = [int][math]::Floor($graph.Canvas.ClientSize.Width / 2)
            [void]$mouseMove.Invoke($graph.Canvas, @([Windows.Forms.MouseEventArgs]::new('None', 0, $center, 120, 0)))
            if ($graph.Canvas.Tag.Cursor -ne 100 -or $graph.Readout.Text -ne 'x = 0    y1 = 0    y2 = 0    y3 = 0') {
                throw '绘图光标坐标不匹配'
            }
            [void]$mouseMove.Invoke($graph.Canvas, @([Windows.Forms.MouseEventArgs]::new('None', 0, 0, 120, 0)))
            if ($graph.Readout.Text -ne 'x = -10    y1 = -10    y2 = 10    y3 = 无值') {
                throw '绘图光标未区分无效采样'
            }
            [void]$mouseLeave.Invoke($graph.Canvas, @([EventArgs]::Empty))
            if ($graph.Canvas.Tag.Cursor -ne -1 -or $graph.Readout.Text -ne '') { throw '绘图光标未清除' }
            [void]$click.Invoke($graph.ZoomIn, @([EventArgs]::Empty))
            if ($graph.Minimum.Text -ne '-5' -or $graph.Maximum.Text -ne '5' -or
                $graph.Canvas.Tag.Series[0].Samples[0] -ne -5000000000L) { throw '绘图放大未按新区间采样' }
            $graph.Canvas.Tag.Cursor = 200
            $wheel = [Windows.Forms.Control].GetMethod('OnMouseWheel', $binding)
            [void]$wheel.Invoke($graph.Window, @([Windows.Forms.MouseEventArgs]::new('None', 0, 0, 0, 120)))
            if ($graph.Minimum.Text -ne '0' -or $graph.Maximum.Text -ne '5') { throw '滚轮缩放未保留光标的横坐标' }
            [void]$click.Invoke($graph.Reset, @([EventArgs]::Empty))
            if ($graph.Minimum.Text -ne '-10' -or $graph.Maximum.Text -ne '10') { throw '绘图重置坐标失败' }
            $mouseDown = [Windows.Forms.Control].GetMethod('OnMouseDown', $binding)
            $mouseUp = [Windows.Forms.Control].GetMethod('OnMouseUp', $binding)
            [void]$mouseDown.Invoke($graph.Canvas, @([Windows.Forms.MouseEventArgs]::new('Left', 1, ($graph.Canvas.Width - 1), 120, 0)))
            [void]$mouseUp.Invoke($graph.Canvas, @([Windows.Forms.MouseEventArgs]::new('Left', 1, 0, 120, 0)))
            if ($graph.Minimum.Text -ne '10' -or $graph.Maximum.Text -ne '30' -or
                $graph.Canvas.Tag.Series[0].Samples[0] -ne 10000000000L) { throw '拖动平移未保留区间宽度或重新采样' }
            $graph.Expression.Text = 'tan(x)'
            $graph.Minimum.Text = '0'
            $graph.Maximum.Text = '2'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $points = $graph.Canvas.Tag.Series[0].Samples
            if ($points[157] -le 10000000000L -or $points[158] -ge -10000000000L) { throw '正切极点两侧采样错误' }
            $bitmap = [Drawing.Bitmap]::new($graph.Canvas.Width, $graph.Canvas.Height)
            try {
                $graph.Canvas.DrawToBitmap($bitmap, $graph.Canvas.ClientRectangle)
                for ($x = 490; $x -le 498; $x++) {
                    if ($bitmap.GetPixel($x, 163).ToArgb() -eq $gold) { throw '正切极点处错误连接了曲线' }
                }
            } finally { $bitmap.Dispose() }
            $graph.Expression.Text = 'sin(pi*x); 1E-3x + e'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($graph.Canvas.Tag.Series[0].Samples[50] -ne 1000000000L -or
                $graph.Canvas.Tag.Series[1].Samples[100] -ne 2719281828L) { throw '绘图常量或科学计数法采样失败' }
            $graph.PointX.Text = '0.123'
            [void]$click.Invoke($graph.Evaluate, @([EventArgs]::Empty))
            if ($graph.Readout.Text -ne 'x = 0.123    y1 = 0.37687101    y2 = 2.718404828') {
                throw "曲线单点求值失败：$($graph.Readout.Text)"
            }
            $graph.Expression.Text = 'x^0.5; 2^x'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $graph.PointX.Text = '0.5'
            [void]$click.Invoke($graph.Evaluate, @([EventArgs]::Empty))
            if ($graph.Readout.Text -ne 'x = 0.5    y1 = 0.707106781    y2 = 1.414213562') {
                throw '绘图小数次幂或变量指数求值失败'
            }
            $graph.Expression.Text = '10*x; sqrt(-1)'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $originalSamples = $graph.Canvas.Tag.Series[0].Samples
            [void]$click.Invoke($graph.Fit, @([EventArgs]::Empty))
            if ($graph.Height.Text -ne '50' -or $graph.Canvas.Tag.Height -ne 50 -or
                ![object]::ReferenceEquals($originalSamples, $graph.Canvas.Tag.Series[0].Samples)) {
                throw '适配纵轴范围或采样保留失败'
            }
            $heightPreview = [Windows.Forms.Control].GetMethod('OnPreviewKeyDown', $binding)
            $heightPreviewEnter = [Windows.Forms.PreviewKeyDownEventArgs]::new([Windows.Forms.Keys]::Enter)
            [void]$heightPreview.Invoke($graph.Height, @($heightPreviewEnter))
            if (!$heightPreviewEnter.IsInputKey) { throw '已有图形时纵轴回车应由输入框处理' }
            $heightKeyDown = [Windows.Forms.TextBox].GetMethod('OnKeyDown', $binding)
            $graph.Height.Text = '0'
            [void]$heightKeyDown.Invoke($graph.Height, @([Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Enter)))
            if ($graph.Canvas.Tag.Height -ne 50 -or $graph.Status.Text -notmatch '纵轴上限须') {
                throw '无效纵轴输入不应更改画面'
            }
            $graph.Height.Text = '25'
            $heightEnter = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Enter)
            [void]$heightKeyDown.Invoke($graph.Height, @($heightEnter))
            if (!$heightEnter.SuppressKeyPress -or $graph.Canvas.Tag.Height -ne 25 -or
                ![object]::ReferenceEquals($originalSamples, $graph.Canvas.Tag.Series[0].Samples)) {
                throw '应用纵轴高度应复用采样'
            }
            $graph.Expression.Text = 'sqrt(-1)'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($graph.Fit.Enabled) { throw '无有效采样时仍可适配纵轴' }
            Clear-CalculatorGraph $graph
            $heightPreviewEnter = [Windows.Forms.PreviewKeyDownEventArgs]::new([Windows.Forms.Keys]::Enter)
            [void]$heightPreview.Invoke($graph.Height, @($heightPreviewEnter))
            if ($heightPreviewEnter.IsInputKey -or $graph.Window.AcceptButton -ne $graph.Draw) {
                throw '没有图形时纵轴回车应保留默认绘制'
            }
            $graph.Expression.Text = 'x'
            $graph.Minimum.Text = '0'
            $graph.Maximum.Text = '2'
            $graph.Density.SelectedItem = '801'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($graph.Canvas.Tag.Steps -ne 800 -or $graph.Canvas.Tag.Series[0].Samples[1] -ne 2500000L -or
                $graph.Canvas.Tag.Series[0].Samples.Count -ne 801) { throw '高密度绘图采样失败' }
            $densePath = Join-Path ([IO.Path]::GetTempPath()) ('BaizeGraph-' + [Guid]::NewGuid() + '.csv')
            try {
                Export-CalculatorGraph $graph.Canvas.Tag $densePath
                $rows = [IO.File]::ReadAllLines($densePath)
                if ($rows.Count -ne 802 -or $rows[2] -ne '0.0025,0.0025' -or $rows[801] -ne '2,2') {
                    throw '高密度绘图 CSV 不匹配'
                }
            } finally { [IO.File]::Delete($densePath) }
            $graph.Expression.Text = 'x^2-2; 1/(x-0.12345)'
            $graph.Minimum.Text = '-2'
            $graph.Maximum.Text = '2'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            [void]$click.Invoke($graph.Roots, @([EventArgs]::Empty))
            if ($graph.Readout.Text -notmatch 'y1：-1\.41421356[0-9], 1\.41421356[0-9]' -or
                $graph.Readout.Text -notmatch 'y2：未找到') { throw "绘图零点定位失败：$($graph.Readout.Text)" }
            $graph.Expression.Text = 'x; x^2; 2*x'
            $graph.Height.Text = '10'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $graph.FirstCurve.SelectedItem = 'y2'
            $graph.SecondCurve.SelectedItem = 'y3'
            [void]$click.Invoke($graph.Intersections, @([EventArgs]::Empty))
            if ($graph.Readout.Text -ne 'y2 与 y3 的交点：(0, 0), (2, 4)' -or
                $graph.Canvas.Tag.Markers.Count -ne 2 -or $graph.Canvas.Tag.Markers[1].Y -ne 4) {
                throw "绘图交点坐标或标记失败：$($graph.Readout.Text)"
            }
            $markerBitmap = [Drawing.Bitmap]::new($graph.Canvas.Width, $graph.Canvas.Height)
            try {
                $graph.Canvas.DrawToBitmap($markerBitmap, $graph.Canvas.ClientRectangle)
                $markerColor = [Drawing.ColorTranslator]::FromHtml('#FAF4E7').ToArgb()
                $pixelX = $graph.Canvas.Width - 2
                $pixelY = [int][math]::Round(($graph.Canvas.Height - 1) * 0.3)
                if ($markerBitmap.GetPixel($pixelX, $pixelY).ToArgb() -ne $markerColor) { throw '交点标记未渲染' }
            } finally { $markerBitmap.Dispose() }
            $graph.FirstCurve.SelectedItem = 'y3'
            [void]$click.Invoke($graph.Intersections, @([EventArgs]::Empty))
            if ($graph.Readout.Text -notmatch '不同的曲线') { throw '重复选择同一条曲线未提示' }
            $graph.Expression.Text = 'x+1e-9; 1e-9'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $graph.FirstCurve.SelectedItem = 'y1'
            $graph.SecondCurve.SelectedItem = 'y2'
            [void]$click.Invoke($graph.Intersections, @([EventArgs]::Empty))
            if ($graph.Readout.Text -ne 'y1 与 y2 的交点：(0, 0.000000001)' -or
                $graph.Canvas.Tag.Markers.Count -ne 1 -or $graph.Canvas.Tag.Markers[0].Y -ne 0.000000001D) {
                throw "极小交点纵坐标丢失精度：$($graph.Readout.Text)"
            }
            [void]$click.Invoke($graph.CopyIntersections, @([EventArgs]::Empty))
            if ($copyState.Text -ne '(0, 0.000000001)' -or $graph.CopyIntersections.Text -ne '已复制') {
                throw '复制交点丢失坐标精度'
            }
            $graph.SecondCurve.SelectedItem = 'y1'
            if ($graph.CopyIntersections.Enabled -or $graph.CopyIntersections.Text -ne '复制交点' -or
                $graph.Canvas.Tag.Markers.Count -ne 0 -or $graph.Readout.Text -ne '') {
                throw '改选曲线后仍保留旧交点'
            }
            $graph.Expression.Text = 'x; x^2; 2*x'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $graph.FirstCurve.SelectedItem = 'y2'
            $graph.SecondCurve.SelectedItem = 'y3'
            [void]$click.Invoke($graph.Intersections, @([EventArgs]::Empty))
            Zoom-CalculatorGraph $graph .5d
            if ($graph.FirstCurve.SelectedItem -ne 'y2' -or $graph.SecondCurve.SelectedItem -ne 'y3' -or
                $graph.CopyIntersections.Enabled -or $graph.Canvas.Tag.Markers.Count -ne 0) {
                throw '缩放后应保留所选曲线并清除旧交点'
            }
            Set-CalculatorGraphRange $graph -1 2
            if ($graph.FirstCurve.SelectedItem -ne 'y2' -or $graph.SecondCurve.SelectedItem -ne 'y3') {
                throw '平移后未保留所选曲线'
            }
            $graph.Minimum.Text = '-0.5'
            $graph.Maximum.Text = '0.5'
            $graph.Density.SelectedItem = '401'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($graph.FirstCurve.SelectedItem -ne 'y2' -or $graph.SecondCurve.SelectedItem -ne 'y3' -or
                $graph.Canvas.Tag.Markers.Count -ne 0 -or $graph.CopyIntersections.Enabled) {
                throw '手动修改范围及密度后应保留所选曲线并清除旧交点'
            }
            $graph.Expression.Text = 'x^2; x*x'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $graph.FirstCurve.SelectedItem = 'y1'
            $graph.SecondCurve.SelectedItem = 'y2'
            [void]$click.Invoke($graph.Intersections, @([EventArgs]::Empty))
            if ($graph.Readout.Text -ne '两条曲线在当前采样点上重合。' -or
                $graph.Canvas.Tag.Markers.Count -ne 0 -or $graph.CopyIntersections.Enabled) {
                throw '重合采样不应误报孤立交点'
            }
            $graph.Expression.Text = '(x-0.001)*(x-0.004)'
            $graph.Minimum.Text = '-1'
            $graph.Maximum.Text = '1'
            $graph.Density.SelectedItem = '801'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            [void]$click.Invoke($graph.Roots, @([EventArgs]::Empty))
            if ($graph.Readout.Text -notmatch 'y1：0\.00[01][0-9]*, 0\.00[34][0-9]*') {
                throw "高密度零点查找失败：$($graph.Readout.Text)"
            }
            $graph.Expression.Text = 'x;  1/0+bad(x)'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            if ($null -ne $graph.Canvas.Tag -or $graph.Status.Text -notmatch '第 2 条 · 第 5 个字符' -or
                $graph.Expression.SelectionStart -ne 8 -or $graph.Expression.SelectedText -ne 'b') {
                throw '绘图未定位错误表达式和字符'
            }
            $graph.Expression.Text = 'sqrt(x); x^2; x+5'
            $graph.Minimum.Text = '-10'
            $graph.Maximum.Text = '10'
            $graph.Density.SelectedItem = '201'
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            $graph.PointX.Text = '-2'
            [void]$click.Invoke($graph.Evaluate, @([EventArgs]::Empty))
            if ($graph.PointResult.Items.Count -ne 2 -or $graph.PointResult.Items[1] -ne 'y3 = 3') {
                throw '绘图点值列表包含无效结果或漏掉有效结果'
            }
            $graph.PointX.Text = '-3'
            if ($graph.ToCalculator.Enabled) { throw '横坐标修改后仍可转入旧点值' }
            $graph.PointX.Text = '-2'
            [void]$click.Invoke($graph.Evaluate, @([EventArgs]::Empty))
            $graph.Expression.Text = 'sqrt(x); x^2; x+8'
            [void]$click.Invoke($graph.Evaluate, @([EventArgs]::Empty))
            if ($null -ne $graph.Canvas.Tag -or $graph.Evaluate.Enabled -or $graph.ToCalculator.Enabled -or
                $graph.Export.Enabled -or $graph.Fit.Enabled -or $graph.Roots.Enabled -or $graph.Intersections.Enabled -or
                $graph.PointResult.Items.Count -ne 0 -or $graph.Legend[0].Text -ne '') {
                throw '修改表达式后仍可查看或使用旧图的数据'
            }
            [void]$click.Invoke($graph.Draw, @([EventArgs]::Empty))
            [void]$click.Invoke($graph.Evaluate, @([EventArgs]::Empty))
            $graph.PointResult.SelectedIndex = 1
            foreach ($key in 'C2*'.ToCharArray()) { Press-CalculatorKey $key }
            [void]$click.Invoke($graph.ToCalculator, @([EventArgs]::Empty))
            Press-CalculatorKey '='
            if ($resultLabel.Text -ne '12') { throw '选定的绘图纵坐标没有进入当前算式' }
        } finally { $graph.Window.Dispose() }
        $preciseGraph = New-GraphDialog
        try {
            $preciseGraph.Expression.Text = 'inv(1000000000)'
            [void]$click.Invoke($preciseGraph.Draw, @([EventArgs]::Empty))
            if ($preciseGraph.Canvas.Tag.Series[0].Samples[0] -ne 1L) { throw '绘图采样丢失第九位' }
            [void]$click.Invoke($preciseGraph.Fit, @([EventArgs]::Empty))
            $fittedHeight = $preciseGraph.Height.Text
            if ($fittedHeight -ne '0.000000002') { throw "极小曲线的适配高度错误：$fittedHeight" }
            [void]$click.Invoke($preciseGraph.Draw, @([EventArgs]::Empty))
            if ($null -eq $preciseGraph.Canvas.Tag -or $preciseGraph.Canvas.Tag.Height -ne 0.000000002D -or
                $preciseGraph.Canvas.Tag.Series[0].Samples[0] -ne 1L) { throw '适配后无法按原纵轴上限重绘' }
            $tinyCsv = Join-Path ([IO.Path]::GetTempPath()) ('BaizeGraph-' + [Guid]::NewGuid() + '.csv')
            try {
                Export-CalculatorGraph $preciseGraph.Canvas.Tag $tinyCsv
                if ([IO.File]::ReadAllLines($tinyCsv)[1] -notmatch ',0\.000000001$') { throw 'CSV 丢失第九位' }
            } finally { [IO.File]::Delete($tinyCsv) }
            $readoutKeyDown = [Windows.Forms.TextBox].GetMethod('OnKeyDown', $binding)
            $stepRight = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Right)
            [void]$readoutKeyDown.Invoke($preciseGraph.Readout, @($stepRight))
            if (!$stepRight.SuppressKeyPress -or $preciseGraph.Canvas.Tag.Cursor -ne 0 -or
                $preciseGraph.Readout.Text -ne 'x = -10    y1 = 0.000000001') { throw '右键未显示首个九位采样点' }
            [void]$readoutKeyDown.Invoke($preciseGraph.Readout, @([Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Right)))
            if ($preciseGraph.Canvas.Tag.Cursor -ne 1) { throw '右键未前进一个采样点' }
            [void]$readoutKeyDown.Invoke($preciseGraph.Readout, @([Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Left)))
            if ($preciseGraph.Canvas.Tag.Cursor -ne 0) { throw '左键未后退一个采样点' }
            $sampleEnter = [Windows.Forms.KeyEventArgs]::new([Windows.Forms.Keys]::Enter)
            [void]$readoutKeyDown.Invoke($preciseGraph.Readout, @($sampleEnter))
            if (!$sampleEnter.SuppressKeyPress -or $preciseGraph.PointX.Text -ne '-10' -or
                $preciseGraph.PointResult.Items[0] -ne 'y1 = 0.000000001' -or !$preciseGraph.ToCalculator.Enabled) {
                throw '键盘选中的采样未进入求点值'
            }
            $preciseGraph.PointX.Text = '1'
            $enterPointInput = [Windows.Forms.Control].GetMethod('OnEnter', $binding)
            $leavePointInput = [Windows.Forms.Control].GetMethod('OnLeave', $binding)
            [void]$enterPointInput.Invoke($preciseGraph.PointX, @([EventArgs]::Empty))
            if ($preciseGraph.Window.AcceptButton -ne $preciseGraph.Evaluate) { throw '点值输入框的回车动作错误' }
            [void]$click.Invoke($preciseGraph.Window.AcceptButton, @([EventArgs]::Empty))
            [void]$leavePointInput.Invoke($preciseGraph.PointX, @([EventArgs]::Empty))
            if ($preciseGraph.Window.AcceptButton -ne $preciseGraph.Draw) { throw '离开点值输入框后未恢复回车绘制' }
            if ($preciseGraph.PointResult.Items[0] -ne 'y1 = 0.000000001') { throw '求点值丢失第九位' }
            foreach ($key in 'C1000000000*'.ToCharArray()) { Press-CalculatorKey $key }
            [void]$click.Invoke($preciseGraph.ToCalculator, @([EventArgs]::Empty))
            Press-CalculatorKey '='
            if ($resultLabel.Text -ne '1') { throw '求点值带回标准模式时丢失精度' }
        } finally { $preciseGraph.Window.Dispose() }
        if ($session.Process.Id -ne $sessionPid) { throw '验收期间计算进程被替换' }
        Write-Output 'PASS: 同一个白泽进程处理全部按键，Windows 桌面计算器的点击、键盘、窗口置顶、紧凑视图、逐步运算、重复等号、百分号、平方根、记忆键、历史持久化、复制和粘贴事件、错误恢复和 BYTE/WORD/DWORD/QWORD 程序员模式及位编辑、单位换算、日期计算、科学计算和绘图'
    } else {
        [void]$form.ShowDialog()
    }
} finally {
    Stop-BaizeSession
    $form.Dispose()
    $compactResultFont.Dispose()
    $smallResultFont.Dispose()
    if ($Verify) { [IO.File]::Delete($historyPath) }
}
