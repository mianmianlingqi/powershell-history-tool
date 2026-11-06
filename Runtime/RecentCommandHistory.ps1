function Invoke-CommandArchiveLock {
    param([scriptblock]$Action)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($global:CommandHistoryArchivePath.ToLowerInvariant())))
    $mutex = [Threading.Mutex]::new($false, "Local\CommandHistoryArchive_$hash")
    $held = $false
    try {
        try { $held = $mutex.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw '历史归档文件正忙，请稍后重试。' }
        & $Action
    }
    finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Initialize-CommandHistoryArchive {
    Invoke-CommandArchiveLock {
        if ([IO.File]::Exists($global:CommandHistoryArchivePath)) { return }
        $directory = [IO.Path]::GetDirectoryName($global:CommandHistoryArchivePath)
        $null = [IO.Directory]::CreateDirectory($directory)
        $temporary = "$global:CommandHistoryArchivePath.$([guid]::NewGuid()).tmp"
        try {
            $writer = [IO.StreamWriter]::new($temporary, $false, [Text.UTF8Encoding]::new($false))
            try {
                $source = (Get-PSReadLineOption).HistorySavePath
                if ([IO.File]::Exists($source)) {
                    $buffer = [Text.StringBuilder]::new()
                    foreach ($line in [IO.File]::ReadLines($source)) {
                        if ($line.EndsWith('`')) {
                            $null = $buffer.Append($line.Substring(0, $line.Length - 1)).Append("`n")
                        }
                        else {
                            $null = $buffer.Append($line)
                            $command = $buffer.ToString()
                            if (-not [string]::IsNullOrWhiteSpace($command)) {
                                $writer.WriteLine((ConvertTo-Json -InputObject $command -Compress))
                            }
                            $null = $buffer.Clear()
                        }
                    }
                    if ($buffer.Length -gt 0) {
                        $writer.WriteLine((ConvertTo-Json -InputObject $buffer.ToString().TrimEnd("`n") -Compress))
                    }
                }
            }
            finally { $writer.Dispose() }
            [IO.File]::Move($temporary, $global:CommandHistoryArchivePath)
        }
        finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
}

function Add-CommandHistoryArchive {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return }
    Initialize-CommandHistoryArchive
    $json = ConvertTo-Json -InputObject $Command -Compress
    Invoke-CommandArchiveLock {
        [IO.File]::AppendAllText($global:CommandHistoryArchivePath, $json + "`n", [Text.UTF8Encoding]::new($false))
    }
}

function Get-RecentPSReadLineCommand {
    [CmdletBinding()]
    param([ValidateRange(0, 2147483647)][int]$Count = 1000)
    Initialize-CommandHistoryArchive
    $commands = [Collections.Generic.List[string]]::new()
    Invoke-CommandArchiveLock {
        if ($Count -eq 0) {
            $lines = [IO.File]::ReadLines($global:CommandHistoryArchivePath)
        }
        else {
            $tail = [int][Math]::Min([int]::MaxValue, [Math]::Max(1024L, 2L * $Count))
            while ($true) {
                $lines = @(Get-Content -LiteralPath $global:CommandHistoryArchivePath -Tail $tail -Encoding utf8)
                $uniqueLines = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($entry in $lines) { if (-not [string]::IsNullOrWhiteSpace($entry)) { $null = $uniqueLines.Add($entry) } }
                if ($uniqueLines.Count -ge $Count -or $lines.Count -lt $tail -or $tail -eq [int]::MaxValue) { break }
                $tail = [int][Math]::Min([int]::MaxValue, 2L * $tail)
            }
        }
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $command = ConvertFrom-Json -InputObject $line -ErrorAction Stop
            if ($command -isnot [string]) { throw '历史归档格式不正确。' }
            $commands.Add($command)
        }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $number = 0
    for ($index = $commands.Count - 1; $index -ge 0; $index--) {
        $command = $commands[$index]
        if ([string]::IsNullOrWhiteSpace($command) -or -not $seen.Add($command)) { continue }
        $number++
        [pscustomobject]@{ '序号' = $number; '命令' = $command }
        if ($Count -gt 0 -and $number -ge $Count) { break }
    }
}

function Find-CommandHistoryMatch {
    [CmdletBinding()]
    param(
        [object[]]$Rows,
        [string]$Query = '',
        [ValidateSet('Contains', 'Keywords', 'Prefix', 'Regex')][string]$Mode = 'Contains',
        [switch]$CaseSensitive
    )
    $comparison = if ($CaseSensitive) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
    $terms = if ($Mode -eq 'Keywords') { @($Query -split '\s+' | Where-Object { $_.Length -gt 0 }) } else { @() }
    $regex = $null
    if ($Mode -eq 'Regex' -and $Query.Length -gt 0) {
        $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
        if (-not $CaseSensitive) { $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }
        try { $regex = [regex]::new($Query, $options, [TimeSpan]::FromMilliseconds(50)) }
        catch { throw '正则表达式无效，请检查括号、转义和语法。' }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($row in $Rows) {
        $command = [string]$row.'命令'
        $matched = $true
        if ($Query.Length -gt 0) {
            switch ($Mode) {
                'Contains' { $matched = $command.IndexOf($Query, $comparison) -ge 0 }
                'Prefix' { $matched = $command.StartsWith($Query, $comparison) }
                'Keywords' {
                    foreach ($term in $terms) {
                        if ($command.IndexOf($term, $comparison) -lt 0) { $matched = $false; break }
                    }
                }
                'Regex' {
                    if ($clock.ElapsedMilliseconds -gt 1500) { throw '正则搜索用时过长，请简化表达式或缩小历史范围。' }
                    try { $matched = $regex.IsMatch($command) }
                    catch [Text.RegularExpressions.RegexMatchTimeoutException] { throw '正则匹配超时，请简化表达式。' }
                }
            }
        }
        if ($matched) { $row }
    }
}

function New-CommandHistoryWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = [Windows.Forms.Form]::new()
    $form.Text = 'PowerShell 历史命令'
    $form.Size = [Drawing.Size]::new(1100, 700)
    $form.MinimumSize = [Drawing.Size]::new(650, 400)
    $form.StartPosition = 'CenterScreen'
    $form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)
    $form.Tag = @{ All = @(Get-RecentPSReadLineCommand -Count 1000); AllLoaded = $false; Limit = 1000; Mode = 'Contains'; Filtered = @(); Selected = $null }
    $top = [Windows.Forms.TableLayoutPanel]::new()
    $top.Dock = 'Top'
    $top.AutoSize = $true
    $top.AutoSizeMode = 'GrowAndShrink'
    $top.ColumnCount = 2
    $top.RowCount = 3
    $null = $top.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::AutoSize))
    $null = $top.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    foreach ($index in 1..3) { $null = $top.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) }
    $rangePanel = [Windows.Forms.FlowLayoutPanel]::new()
    $rangePanel.AutoSize = $true
    $rangePanel.Dock = 'Fill'
    $rangePanel.WrapContents = $false
    $modePanel = [Windows.Forms.FlowLayoutPanel]::new()
    $modePanel.AutoSize = $true
    $modePanel.Dock = 'Fill'
    $modePanel.FlowDirection = 'RightToLeft'
    $recent = [Windows.Forms.Button]::new()
    $recent.Text = '最近 1000 条'
    $recent.AutoSize = $true
    $all = [Windows.Forms.Button]::new()
    $all.Text = '全部历史'
    $all.AutoSize = $true
    $search = [Windows.Forms.TextBox]::new()
    $search.Dock = 'Fill'
    $search.PlaceholderText = '搜索当前范围内的命令'
    $status = [Windows.Forms.Label]::new()
    $status.AutoSize = $true
    $caseSensitive = [Windows.Forms.CheckBox]::new()
    $caseSensitive.Text = '区分大小写'
    $caseSensitive.AutoSize = $true
    $modePanel.Controls.Add($caseSensitive)
    $modeButtons = @{}
    foreach ($definition in @(@('Regex', '正则表达式'), @('Prefix', '开头匹配'), @('Keywords', '多个关键词'), @('Contains', '包含文字'))) {
        $button = [Windows.Forms.RadioButton]::new()
        $button.Text = $definition[1]
        $button.Tag = $definition[0]
        $button.Appearance = 'Button'
        $button.AutoSize = $true
        $button.Checked = $definition[0] -eq 'Contains'
        $modeButtons[$definition[0]] = $button
        $modePanel.Controls.Add($button)
    }
    $rangePanel.Controls.AddRange(@($recent, $all))
    $top.Controls.Add($rangePanel, 0, 0)
    $top.Controls.Add($modePanel, 1, 0)
    $top.Controls.Add($search, 0, 1)
    $top.SetColumnSpan($search, 2)
    $top.Controls.Add($status, 0, 2)
    $top.SetColumnSpan($status, 2)
    $list = [Windows.Forms.ListView]::new()
    $list.Dock = 'Fill'
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.VirtualMode = $true
    $null = $list.Columns.Add('序号', 70)
    $null = $list.Columns.Add('命令', 1400)
    $bottom = [Windows.Forms.FlowLayoutPanel]::new()
    $bottom.Dock = 'Bottom'
    $bottom.Height = 42
    $bottom.FlowDirection = 'RightToLeft'
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.DialogResult = 'Cancel'
    $accept = [Windows.Forms.Button]::new()
    $accept.Text = '填回输入行'
    $accept.AutoSize = $true
    $bottom.Controls.AddRange(@($cancel, $accept))
    $form.Controls.AddRange(@($list, $top, $bottom))
    $form.CancelButton = $cancel
    $form.AcceptButton = $accept
    $form.Tag.List = $list
    $form.Tag.Search = $search
    $form.Tag.Status = $status
    $form.Tag.Recent = $recent
    $form.Tag.AllButton = $all
    $form.Tag.ModeButtons = $modeButtons
    $form.Tag.CaseSensitive = $caseSensitive
    $update = {
        param($sender, $eventArgs)
        $window = $sender.FindForm()
        $state = $window.Tag
        $state.List.SelectedIndices.Clear()
        $state.List.VirtualListSize = 0
        $scope = if ($state.Limit -eq 0) { $state.All } else { @($state.All | Select-Object -First $state.Limit) }
        $term = $state.Search.Text
        $state.Recent.Enabled = $state.Limit -ne 1000
        $state.AllButton.Enabled = $state.Limit -ne 0
        $state.Status.ForeColor = [Drawing.SystemColors]::ControlText
        try { $state.Filtered = @(Find-CommandHistoryMatch -Rows $scope -Query $term -Mode $state.Mode -CaseSensitive:$state.CaseSensitive.Checked) }
        catch {
            $state.Filtered = @()
            $state.Status.Text = $_.Exception.Message
            $state.Status.ForeColor = [Drawing.Color]::Firebrick
            return
        }
        $state.List.VirtualListSize = $state.Filtered.Count
        $state.List.Invalidate()
        $state.Status.Text = if ($state.AllLoaded) { "显示 $($state.Filtered.Count) 条，共 $($state.All.Count) 条不同命令" } else { "显示 $($state.Filtered.Count) 条，范围：最近 1000 条" }
    }
    $form.Tag.Update = $update
    $list.add_RetrieveVirtualItem({
        param($sender, $eventArgs)
        $row = $sender.FindForm().Tag.Filtered[$eventArgs.ItemIndex]
        $item = [Windows.Forms.ListViewItem]::new([string]$row.'序号')
        $null = $item.SubItems.Add(($row.'命令' -replace '\r?\n', ' ↵ '))
        $eventArgs.Item = $item
    })
    $recent.add_Click({ param($sender, $e) $sender.FindForm().Tag.Limit = 1000; & $sender.FindForm().Tag.Update $sender $e })
    $all.add_Click({
        param($sender, $e)
        $window = $sender.FindForm()
        try {
            $window.UseWaitCursor = $true
            if (-not $window.Tag.AllLoaded) {
                $window.Tag.All = @(Get-RecentPSReadLineCommand -Count 0)
                $window.Tag.AllLoaded = $true
            }
            $window.Tag.Limit = 0
            & $window.Tag.Update $sender $e
        }
        catch { $null = [Windows.Forms.MessageBox]::Show($window, $_.Exception.Message, '读取历史失败') }
        finally { $window.UseWaitCursor = $false }
    })
    $search.add_TextChanged($update)
    $caseSensitive.add_CheckedChanged($update)
    foreach ($button in $modeButtons.Values) {
        $button.add_CheckedChanged({
            param($sender, $e)
            if ($sender.Checked) {
                $sender.FindForm().Tag.Mode = [string]$sender.Tag
                & $sender.FindForm().Tag.Update $sender $e
            }
        })
    }
    $choose = {
        param($sender, $e)
        $window = $sender.FindForm()
        if ($window.Tag.List.SelectedIndices.Count -eq 0) { return }
        $window.Tag.Selected = $window.Tag.Filtered[$window.Tag.List.SelectedIndices[0]].'命令'
        $window.DialogResult = 'OK'
        $window.Close()
    }
    $accept.add_Click($choose)
    $list.add_DoubleClick($choose)
    $form.add_Shown({
        param($sender, $e)
        $sender.BringToFront()
        $null = $sender.Activate()
        & $sender.Tag.Update $sender.Tag.Search $e
        $null = $sender.Tag.Search.Focus()
    })
    return $form
}

function Show-CommandHistoryWindow {
    $form = New-CommandHistoryWindow
    try {
        if ($form.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $form.Tag.Selected }
    }
    finally { $form.Dispose() }
}

if (-not (Get-Variable CommandHistoryArchivePath -Scope Global -ErrorAction SilentlyContinue)) {
    $global:CommandHistoryArchivePath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PowerShell\HistoryArchive\commands.jsonl'
}
# Do not wrap our own handler when the profile is reloaded.
if (-not (Get-Variable CommandHistoryOriginalHandler -Scope Global -ErrorAction SilentlyContinue)) {
    $global:CommandHistoryOriginalHandler = (Get-PSReadLineOption).AddToHistoryHandler
}
try { Initialize-CommandHistoryArchive }
catch { Write-Warning "历史归档暂不可用，快捷键仍会注册：$($_.Exception.Message)" }
Set-PSReadLineOption -AddToHistoryHandler {
    param($command)
    $decision = if ($null -ne $global:CommandHistoryOriginalHandler) {
        $global:CommandHistoryOriginalHandler.Invoke($command)
    }
    else { [Microsoft.PowerShell.PSConsoleReadLine]::GetDefaultAddToHistoryOption($command) }
    $save = if ($decision -is [bool]) { $decision } else { [string]$decision -eq 'MemoryAndFile' }
    if ($save) {
        try { Add-CommandHistoryArchive -Command $command }
        catch { Write-Warning "历史归档写入失败：$($_.Exception.Message)" }
    }
    return $decision
}
function global:Enable-CommandHistoryShortcut {
    param([switch]$Force)
    $binding = Get-PSReadLineKeyHandler -Chord Ctrl+h -ErrorAction SilentlyContinue
    if ($null -ne $binding -and $binding.Function -eq 'CommandHistoryArchive') { return }
    if (-not $Force -and $null -ne $binding -and $binding.Function -notin @('BackwardDeleteChar', 'Unbound')) { return }
    Set-PSReadLineKeyHandler -Chord Ctrl+h -BriefDescription CommandHistoryArchive -LongDescription '搜索历史命令，切换最近 1000 条或全部历史' -ScriptBlock {
        param($key, $arg)
        try {
            $selected = Show-CommandHistoryWindow
            if ($null -ne $selected) {
                $line = $null
                $cursor = 0
                [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
                [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $line.Length, [string]$selected)
            }
        }
        catch { Write-Warning "历史窗口打开失败：$($_.Exception.Message)" }
    }
}

function global:Invoke-CommandHistoryReadLine {
    param([bool]$LastRunStatus)
    [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine($host.Runspace, $ExecutionContext, $LastRunStatus)
}

function Get-CommandHistoryStatus {
    $activeReader = Get-Command PSConsoleHostReadLine -ErrorAction SilentlyContinue
    $owned = Get-Variable CommandHistoryOwnedReader -Scope Global -ErrorAction SilentlyContinue
    $hookActive = $null -ne $activeReader -and $null -ne $owned -and $activeReader.ScriptBlock -eq $owned.Value
    $lastError = Get-Variable CommandHistoryShortcutError -Scope Global -ErrorAction SilentlyContinue
    $currentBinding = Get-PSReadLineKeyHandler -Chord Ctrl+h -ErrorAction SilentlyContinue
    [pscustomobject]@{
        ToolVersion = '1.1.0'
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PSReadLineVersion = (Get-Module PSReadLine).Version.ToString()
        CtrlHBinding = if ($null -ne $currentBinding) { $currentBinding.Function } else { 'Unbound' }
        InputHook = if ($hookActive) { 'Enabled' } else { 'NotActive' }
        LastShortcutError = if ($null -ne $lastError) { $lastError.Value } else { $null }
        ArchiveExists = [IO.File]::Exists($global:CommandHistoryArchivePath)
        ApartmentState = [Threading.Thread]::CurrentThread.GetApartmentState().ToString()
    }
}

$commandHistoryPreviousBinding = Get-PSReadLineKeyHandler -Chord Ctrl+Alt+h -ErrorAction SilentlyContinue
if ($null -ne $commandHistoryPreviousBinding -and $commandHistoryPreviousBinding.Function -in @('CommandHistoryArchive', 'RecentHistory100')) {
    Remove-PSReadLineKeyHandler -Chord Ctrl+Alt+h
}
Enable-CommandHistoryShortcut -Force
# Recheck at the next input line; EditMode changes reset PSReadLine's key maps.
# Keep the last command status as the first statement, matching PSReadLine itself.
$commandHistoryReaderInfo = Get-Command PSConsoleHostReadLine -ErrorAction SilentlyContinue
$commandHistoryOwnedReaderInfo = Get-Variable CommandHistoryOwnedReader -Scope Global -ErrorAction SilentlyContinue
if ($null -ne $commandHistoryReaderInfo -and ($commandHistoryReaderInfo.Source -eq 'PSReadLine' -or ($null -ne $commandHistoryOwnedReaderInfo -and $commandHistoryReaderInfo.ScriptBlock -eq $commandHistoryOwnedReaderInfo.Value))) {
    function global:PSConsoleHostReadLine {
        [System.Diagnostics.DebuggerHidden()]
        param()
        $lastRunStatus = $?
        Microsoft.PowerShell.Core\Set-StrictMode -Off
        try {
            Enable-CommandHistoryShortcut
            $global:CommandHistoryShortcutError = $null
        }
        catch { $global:CommandHistoryShortcutError = $_.Exception.Message }
        Invoke-CommandHistoryReadLine -LastRunStatus $lastRunStatus
    }
    $global:CommandHistoryOwnedReader = (Get-Command PSConsoleHostReadLine).ScriptBlock
    $global:CommandHistoryInputHook = 'Enabled'
}
else {
    $global:CommandHistoryInputHook = 'CustomReaderPreserved'
}
