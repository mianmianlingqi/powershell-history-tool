param([switch]$NoConsoleIntegration)

function Invoke-CommandArchiveLock {
    param([scriptblock]$Action, [string]$Path = $global:CommandHistoryArchivePath, [ValidateSet('Local', 'Global')][string]$Scope = 'Local')
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToLowerInvariant())))
    $mutex = [Threading.Mutex]::new($false, "$Scope\CommandHistoryArchive_$hash")
    $held = $false
    try {
        try { $held = $mutex.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw '命令数据文件正忙，请稍后重试。' }
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
    $lines = Invoke-CommandArchiveLock {
        if ($Count -eq 0) {
            $lines = [IO.File]::ReadAllLines($global:CommandHistoryArchivePath)
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
        ,$lines
    }
    # Parsing must not hold the writer lock for the entire archive scan.
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $command = ConvertFrom-Json -InputObject $line -ErrorAction Stop
        if ($command -isnot [string]) { throw '历史归档格式不正确。' }
        $commands.Add($command)
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

function Read-CommonCommandStore {
    if (-not [IO.File]::Exists($global:CommonCommandRegistryPath)) { return [pscustomobject]@{ SchemaVersion = 1; Commands = @() } }
    try { $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($global:CommonCommandRegistryPath)) -ErrorAction Stop }
    catch { throw '无法读取常用命令文件，请检查文件内容或权限；未修改文件。' }
    if ($null -eq $document -or $document.SchemaVersion -ne 1 -or $null -eq $document.Commands) { throw '常用命令文件格式不正确，未修改文件。' }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $document.Commands) {
        if ($null -eq $entry.PSObject.Properties['Description'] -or $null -eq $entry.Description) { $entry | Add-Member -NotePropertyName Description -NotePropertyValue '' -Force }
        if ($entry.Name -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Name) -or
            $entry.Command -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Command) -or
            $entry.Description -isnot [string] -or -not $names.Add($entry.Name)) { throw '常用命令记录无效或名称重复，未修改文件。' }
        if ($null -eq $entry.PSObject.Properties['Revision'] -or [string]::IsNullOrWhiteSpace([string]$entry.Revision)) {
            $content = ConvertTo-Json -InputObject @($entry.Name, $entry.Command, $entry.Description) -Compress
            $revision = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($content)))
            $entry | Add-Member -NotePropertyName Revision -NotePropertyValue $revision -Force
        }
    }
    return $document
}

function Write-CommonCommandStore {
    param([object]$Document)
    $directory = [IO.Path]::GetDirectoryName($global:CommonCommandRegistryPath)
    $null = [IO.Directory]::CreateDirectory($directory)
    $temporary = "$global:CommonCommandRegistryPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $Document -Depth 6
        [IO.File]::WriteAllText($temporary, $json + "`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $global:CommonCommandRegistryPath, $true)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-CommonCommand {
    [CmdletBinding()]
    param([string]$Name)
    $filterByName = $PSBoundParameters.ContainsKey('Name')
    Invoke-CommandArchiveLock -Path $global:CommonCommandRegistryPath -Scope Global -Action {
        $document = Read-CommonCommandStore
        @($document.Commands) | Where-Object { -not $filterByName -or [string]::Equals($_.Name, $Name, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object Name
    }
}

function Register-CommonCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Command,
        [string]$Description = '',
        [switch]$Force,
        [string]$ExpectedRevision
    )
    $Name = $Name.Trim()
    if ($Name.Length -eq 0 -or $Name.Length -gt 80 -or $Name -match '[\x00-\x1f]') { throw '名称须为 1 至 80 个字符，不能包含换行或控制字符。' }
    if ([string]::IsNullOrWhiteSpace($Command)) { throw '命令内容不能为空。' }
    $checkRevision = $PSBoundParameters.ContainsKey('ExpectedRevision')
    Invoke-CommandArchiveLock -Path $global:CommonCommandRegistryPath -Scope Global -Action {
        $document = Read-CommonCommandStore
        $existing = @($document.Commands | Where-Object { [string]::Equals($_.Name, $Name, [StringComparison]::OrdinalIgnoreCase) })
        if ($checkRevision -and ($existing.Count -ne 1 -or $existing[0].Revision -ne $ExpectedRevision)) { throw '该记录已被其他用户或 agent 修改或删除，请关闭编辑窗口并刷新后重试。' }
        if ($existing.Count -gt 0 -and -not $Force) { throw '该名称已存在，更新时请明确使用 -Force。' }
        $now = [DateTime]::UtcNow.ToString('o')
        $entry = [pscustomobject]@{
            Name = $Name; Command = $Command; Description = $Description
            CreatedAtUtc = if ($existing.Count -gt 0 -and $null -ne $existing[0].PSObject.Properties['CreatedAtUtc']) { $existing[0].CreatedAtUtc } else { $now }
            UpdatedAtUtc = $now
            Revision = [guid]::NewGuid().ToString('N')
        }
        $document.Commands = @(@($document.Commands | Where-Object { -not [string]::Equals($_.Name, $Name, [StringComparison]::OrdinalIgnoreCase) }) + $entry)
        Write-CommonCommandStore $document
        $entry
    }
}

function Unregister-CommonCommand {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name)
    if (-not $PSCmdlet.ShouldProcess($Name, '移除常用命令')) { return }
    Invoke-CommandArchiveLock -Path $global:CommonCommandRegistryPath -Scope Global -Action {
        $document = Read-CommonCommandStore
        $remaining = @($document.Commands | Where-Object { -not [string]::Equals($_.Name, $Name, [StringComparison]::OrdinalIgnoreCase) })
        if ($remaining.Count -eq @($document.Commands).Count) { throw "未找到常用命令：$Name" }
        $document.Commands = $remaining
        Write-CommonCommandStore $document
    }
}

function hcmd {
    [CmdletBinding()]
    param([ValidateSet('list', 'add', 'remove')][string]$Action = 'list', [string]$Name, [string]$Command, [string]$Description = '', [switch]$Force)
    switch ($Action) {
        'list' { if ($PSBoundParameters.ContainsKey('Name')) { Get-CommonCommand -Name $Name } else { Get-CommonCommand } }
        'add' {
            if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Command)) { throw '用法：hcmd add -Name 名称 -Command 命令 [-Description 说明] [-Force]' }
            Register-CommonCommand -Name $Name -Command $Command -Description $Description -Force:$Force
        }
        'remove' {
            if ([string]::IsNullOrWhiteSpace($Name)) { throw '用法：hcmd remove -Name 名称' }
            Unregister-CommonCommand -Name $Name
        }
    }
}

function Get-CommonCommandRows {
    $number = 0
    foreach ($entry in @(Get-CommonCommand)) {
        $number++
        [pscustomobject]@{ '序号' = $number; '名称' = $entry.Name; '命令' = $entry.Command; '说明' = $entry.Description }
    }
}

function Find-CommandHistoryMatch {
    [CmdletBinding()]
    param(
        [object[]]$Rows,
        [string]$Query = '',
        [ValidateSet('Contains', 'Keywords', 'Prefix', 'Regex')][string]$Mode = 'Contains',
        [switch]$CaseSensitive,
        [string[]]$SearchFields = @('命令')
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
        $texts = @(foreach ($field in $SearchFields) {
            $property = $row.PSObject.Properties[$field]
            if ($null -ne $property) { [string]$property.Value }
        })
        $matched = $true
        if ($Query.Length -gt 0) {
            switch ($Mode) {
                'Contains' { $matched = $false; foreach ($text in $texts) { if ($text.IndexOf($Query, $comparison) -ge 0) { $matched = $true; break } } }
                'Prefix' { $matched = $false; foreach ($text in $texts) { if ($text.StartsWith($Query, $comparison)) { $matched = $true; break } } }
                'Keywords' {
                    foreach ($term in $terms) {
                        $found = $false
                        foreach ($text in $texts) { if ($text.IndexOf($term, $comparison) -ge 0) { $found = $true; break } }
                        if (-not $found) { $matched = $false; break }
                    }
                }
                'Regex' {
                    if ($clock.ElapsedMilliseconds -gt 1500) { throw '正则搜索用时过长，请简化表达式或缩小历史范围。' }
                    try { $matched = $false; foreach ($text in $texts) { if ($regex.IsMatch($text)) { $matched = $true; break } } }
                    catch [Text.RegularExpressions.RegexMatchTimeoutException] { throw '正则匹配超时，请简化表达式。' }
                }
            }
        }
        if ($matched) { $row }
    }
}

function New-CommonCommandEditor {
    param([object]$Entry, [string]$Command = '')
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $dialog = [Windows.Forms.Form]::new()
    $dialog.Text = if ($null -ne $Entry) { '编辑常用命令' } else { '注册常用命令' }
    $dialog.Size = [Drawing.Size]::new(760, 540)
    $dialog.MinimumSize = [Drawing.Size]::new(560, 420)
    $dialog.StartPosition = 'CenterParent'
    $dialog.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)
    $layout = [Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock = 'Fill'
    $layout.Padding = [Windows.Forms.Padding]::new(10)
    $layout.ColumnCount = 2
    $layout.RowCount = 5
    $null = $layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::AutoSize))
    $null = $layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    foreach ($style in @([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize), [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 70), [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 30), [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize), [Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))) { $null = $layout.RowStyles.Add($style) }
    $nameBox = [Windows.Forms.TextBox]::new()
    $nameBox.Dock = 'Fill'
    $nameBox.MaxLength = 80
    $commandBox = [Windows.Forms.TextBox]::new()
    $commandBox.Dock = 'Fill'
    $commandBox.Multiline = $true
    $commandBox.AcceptsReturn = $true
    $commandBox.ScrollBars = 'Both'
    $commandBox.WordWrap = $false
    $commandBox.Text = $Command
    $descriptionBox = [Windows.Forms.TextBox]::new()
    $descriptionBox.Dock = 'Fill'
    $descriptionBox.Multiline = $true
    $descriptionBox.AcceptsReturn = $true
    if ($null -ne $Entry) {
        $nameBox.Text = [string]$Entry.Name
        $nameBox.ReadOnly = $true
        $commandBox.Text = [string]$Entry.Command
        $descriptionBox.Text = [string]$Entry.Description
    }
    $row = 0
    foreach ($definition in @(@('名称', $nameBox), @('命令内容', $commandBox), @('说明', $descriptionBox))) {
        $label = [Windows.Forms.Label]::new()
        $label.Text = $definition[0]
        $label.AutoSize = $true
        $layout.Controls.Add($label, 0, $row)
        $layout.Controls.Add($definition[1], 1, $row)
        $row++
    }
    $errorLabel = [Windows.Forms.Label]::new()
    $errorLabel.AutoSize = $true
    $errorLabel.ForeColor = [Drawing.Color]::Firebrick
    $layout.Controls.Add($errorLabel, 0, 3)
    $layout.SetColumnSpan($errorLabel, 2)
    $buttons = [Windows.Forms.FlowLayoutPanel]::new()
    $buttons.AutoSize = $true
    $buttons.Dock = 'Fill'
    $buttons.FlowDirection = 'RightToLeft'
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.DialogResult = 'Cancel'
    $save = [Windows.Forms.Button]::new()
    $save.Text = '保存'
    $buttons.Controls.AddRange(@($cancel, $save))
    $layout.Controls.Add($buttons, 0, 4)
    $layout.SetColumnSpan($buttons, 2)
    $dialog.Controls.Add($layout)
    $dialog.AcceptButton = $save
    $dialog.CancelButton = $cancel
    $dialog.Tag = @{ NameBox = $nameBox; CommandBox = $commandBox; DescriptionBox = $descriptionBox; ErrorLabel = $errorLabel; SaveButton = $save; IsEdit = ($null -ne $Entry); OriginalRevision = if ($null -ne $Entry) { $Entry.Revision } else { '' } }
    $save.add_Click({
        param($sender, $e)
        $window = $sender.FindForm()
        $state = $window.Tag
        try {
            $arguments = @{ Name = $state.NameBox.Text; Command = $state.CommandBox.Text; Description = $state.DescriptionBox.Text; Force = $state.IsEdit }
            if ($state.IsEdit) { $arguments.ExpectedRevision = $state.OriginalRevision }
            $null = Register-CommonCommand @arguments
            $window.DialogResult = 'OK'
            $window.Close()
        }
        catch { $state.ErrorLabel.Text = $_.Exception.Message }
    })
    return $dialog
}

function Show-CommonCommandEditor {
    param([Windows.Forms.Form]$Owner, [object]$Entry, [string]$Command = '')
    $dialog = New-CommonCommandEditor -Entry $Entry -Command $Command
    try { return $dialog.ShowDialog($Owner) -eq [Windows.Forms.DialogResult]::OK }
    finally { $dialog.Dispose() }
}

function New-CommandHistoryWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = [Windows.Forms.Form]::new()
    $form.Text = 'PowerShell 历史与常用命令'
    $form.Size = [Drawing.Size]::new(1100, 700)
    $form.MinimumSize = [Drawing.Size]::new(650, 400)
    $form.StartPosition = 'CenterScreen'
    $form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)
    $historyRows = @()
    $historyError = ''
    try { $historyRows = @(Get-RecentPSReadLineCommand -Count 1000) }
    catch { $historyError = "历史读取失败：$($_.Exception.Message)；仍可切换常用命令。" }
    $form.Tag = @{ All = $historyRows; HistoryError = $historyError; AllLoaded = $false; Limit = 1000; Mode = 'Contains'; View = 'History'; CommonRows = @(); Filtered = @(); Selected = $null }
    $top = [Windows.Forms.TableLayoutPanel]::new()
    $top.Dock = 'Top'
    $top.AutoSize = $true
    $top.AutoSizeMode = 'GrowAndShrink'
    $top.ColumnCount = 2
    $top.RowCount = 4
    $null = $top.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::AutoSize))
    $null = $top.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    foreach ($index in 1..4) { $null = $top.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize)) }
    $navigation = [Windows.Forms.FlowLayoutPanel]::new()
    $navigation.AutoSize = $true
    $navigation.Dock = 'Fill'
    $historyView = [Windows.Forms.Button]::new()
    $historyView.Text = '历史记录'
    $historyView.AutoSize = $true
    $commonView = [Windows.Forms.Button]::new()
    $commonView.Text = '常用命令'
    $commonView.AutoSize = $true
    $addCommon = [Windows.Forms.Button]::new()
    $addCommon.Text = '新增'
    $editCommon = [Windows.Forms.Button]::new()
    $editCommon.Text = '编辑'
    $removeCommon = [Windows.Forms.Button]::new()
    $removeCommon.Text = '删除'
    $refreshCommon = [Windows.Forms.Button]::new()
    $refreshCommon.Text = '刷新'
    $captureCommon = [Windows.Forms.Button]::new()
    $captureCommon.Text = '注册所选'
    $captureCommon.AutoSize = $true
    $navigation.Controls.AddRange(@($historyView, $commonView, $addCommon, $editCommon, $removeCommon, $refreshCommon, $captureCommon))
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
    $top.Controls.Add($navigation, 0, 0)
    $top.SetColumnSpan($navigation, 2)
    $top.Controls.Add($rangePanel, 0, 1)
    $top.Controls.Add($modePanel, 1, 1)
    $top.Controls.Add($search, 0, 2)
    $top.SetColumnSpan($search, 2)
    $top.Controls.Add($status, 0, 3)
    $top.SetColumnSpan($status, 2)
    $list = [Windows.Forms.ListView]::new()
    $list.Dock = 'Fill'
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.VirtualMode = $true
    $null = $list.Columns.Add('序号', 70)
    $null = $list.Columns.Add('名称', 0)
    $null = $list.Columns.Add('命令', 1400)
    $null = $list.Columns.Add('说明', 0)
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
    $form.Tag.HistoryViewButton = $historyView
    $form.Tag.CommonViewButton = $commonView
    $form.Tag.AddCommonButton = $addCommon
    $form.Tag.EditCommonButton = $editCommon
    $form.Tag.RemoveCommonButton = $removeCommon
    $form.Tag.RefreshCommonButton = $refreshCommon
    $form.Tag.CaptureCommonButton = $captureCommon
    $update = {
        param($sender, $eventArgs)
        $window = $sender.FindForm()
        $state = $window.Tag
        $state.List.SelectedIndices.Clear()
        $state.List.VirtualListSize = 0
        $isCommon = $state.View -eq 'Common'
        $scope = if ($isCommon) { $state.CommonRows } elseif ($state.Limit -eq 0) { $state.All } else { @($state.All | Select-Object -First $state.Limit) }
        $state.HistoryViewButton.Enabled = $isCommon
        $state.CommonViewButton.Enabled = -not $isCommon
        foreach ($button in @($state.AddCommonButton, $state.EditCommonButton, $state.RemoveCommonButton, $state.RefreshCommonButton)) { $button.Visible = $isCommon }
        $state.EditCommonButton.Enabled = $false
        $state.RemoveCommonButton.Enabled = $false
        $state.CaptureCommonButton.Visible = -not $isCommon
        $state.CaptureCommonButton.Enabled = $false
        $state.Recent.Visible = -not $isCommon
        $state.AllButton.Visible = -not $isCommon
        $state.List.Columns[1].Width = if ($isCommon) { 160 } else { 0 }
        $state.List.Columns[2].Width = if ($isCommon) { 650 } else { 1400 }
        $state.List.Columns[3].Width = if ($isCommon) { 300 } else { 0 }
        $term = $state.Search.Text
        $state.Recent.Enabled = $state.Limit -ne 1000
        $state.AllButton.Enabled = $state.Limit -ne 0
        $state.Status.ForeColor = [Drawing.SystemColors]::ControlText
        $fields = if ($isCommon) { @('名称', '命令', '说明') } else { @('命令') }
        try { $state.Filtered = @(Find-CommandHistoryMatch -Rows $scope -Query $term -Mode $state.Mode -CaseSensitive:$state.CaseSensitive.Checked -SearchFields $fields) }
        catch {
            $state.Filtered = @()
            $state.Status.Text = $_.Exception.Message
            $state.Status.ForeColor = [Drawing.Color]::Firebrick
            return
        }
        $state.List.VirtualListSize = $state.Filtered.Count
        $state.List.Invalidate()
        $state.Status.Text = if ($isCommon) { "显示 $($state.Filtered.Count) 条，共 $($state.CommonRows.Count) 条常用命令；可搜索名称、命令和说明" } elseif ($state.AllLoaded) { "显示 $($state.Filtered.Count) 条，共 $($state.All.Count) 条不同命令" } else { "显示 $($state.Filtered.Count) 条，范围：最近 1000 条" }
        if (-not $isCommon -and $state.HistoryError) { $state.Status.Text = $state.HistoryError; $state.Status.ForeColor = [Drawing.Color]::Firebrick }
    }
    $form.Tag.Update = $update
    $list.add_RetrieveVirtualItem({
        param($sender, $eventArgs)
        $row = $sender.FindForm().Tag.Filtered[$eventArgs.ItemIndex]
        $item = [Windows.Forms.ListViewItem]::new([string]$row.'序号')
        $null = $item.SubItems.Add($(if ($null -ne $row.PSObject.Properties['名称']) { [string]$row.'名称' } else { '' }))
        $null = $item.SubItems.Add(($row.'命令' -replace '\r?\n', ' ↵ '))
        $null = $item.SubItems.Add($(if ($null -ne $row.PSObject.Properties['说明']) { [string]$row.'说明' -replace '\r?\n', ' ↵ ' } else { '' }))
        $eventArgs.Item = $item
    })
    $refreshRegistered = {
        param($sender, $e)
        $window = $sender.FindForm()
        try {
            $rows = @(Get-CommonCommandRows)
            $window.Tag.CommonRows = $rows
            $window.Tag.View = 'Common'
            & $window.Tag.Update $sender $e
        }
        catch { $window.Tag.Status.Text = $_.Exception.Message; $window.Tag.Status.ForeColor = [Drawing.Color]::Firebrick }
    }
    $form.Tag.RefreshRegistered = $refreshRegistered
    $commonView.add_Click($refreshRegistered)
    $refreshCommon.add_Click($refreshRegistered)
    $historyView.add_Click({ param($sender, $e) $sender.FindForm().Tag.View = 'History'; & $sender.FindForm().Tag.Update $sender $e })
    $list.add_SelectedIndexChanged({
        param($sender, $e)
        $state = $sender.FindForm().Tag
        $hasSelection = $sender.SelectedIndices.Count -eq 1
        $state.EditCommonButton.Enabled = $hasSelection -and $state.View -eq 'Common'
        $state.RemoveCommonButton.Enabled = $hasSelection -and $state.View -eq 'Common'
        $state.CaptureCommonButton.Enabled = $hasSelection -and $state.View -eq 'History'
    })
    $addCommon.add_Click({
        param($sender, $e)
        $window = $sender.FindForm()
        if (Show-CommonCommandEditor -Owner $window) { & $window.Tag.RefreshRegistered $sender $e }
    })
    $editCommon.add_Click({
        param($sender, $e)
        $window = $sender.FindForm()
        if ($window.Tag.List.SelectedIndices.Count -ne 1) { return }
        try {
            $row = $window.Tag.Filtered[$window.Tag.List.SelectedIndices[0]]
            $entry = Get-CommonCommand -Name $row.'名称'
            if ($null -eq $entry) { throw '该记录已被移除，请刷新列表。' }
            if (Show-CommonCommandEditor -Owner $window -Entry $entry) { & $window.Tag.RefreshRegistered $sender $e }
        }
        catch { $window.Tag.Status.Text = $_.Exception.Message }
    })
    $removeCommon.add_Click({
        param($sender, $e)
        $window = $sender.FindForm()
        if ($window.Tag.List.SelectedIndices.Count -ne 1) { return }
        $row = $window.Tag.Filtered[$window.Tag.List.SelectedIndices[0]]
        if ([Windows.Forms.MessageBox]::Show($window, "移除常用命令：$($row.'名称')？历史记录不会被删除。", '确认移除', 'YesNo', 'Question') -ne 'Yes') { return }
        try { Unregister-CommonCommand -Name $row.'名称' -Confirm:$false; & $window.Tag.RefreshRegistered $sender $e }
        catch { $window.Tag.Status.Text = $_.Exception.Message }
    })
    $captureCommon.add_Click({
        param($sender, $e)
        $window = $sender.FindForm()
        if ($window.Tag.List.SelectedIndices.Count -ne 1) { return }
        $row = $window.Tag.Filtered[$window.Tag.List.SelectedIndices[0]]
        if (Show-CommonCommandEditor -Owner $window -Command $row.'命令') { & $window.Tag.RefreshRegistered $sender $e }
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
                $window.Tag.HistoryError = ''
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
if (-not (Get-Variable CommonCommandRegistryPath -Scope Global -ErrorAction SilentlyContinue)) {
    $global:CommonCommandRegistryPath = Join-Path ([IO.Path]::GetDirectoryName($global:CommandHistoryArchivePath)) 'common-commands.json'
}
if ($NoConsoleIntegration) { return }
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
        ToolVersion = '1.2.0'
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
