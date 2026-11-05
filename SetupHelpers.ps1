function Read-HistoryToolProfile {
    param([string]$Path)
    # BOM-aware; reject legacy non-UTF-8 text instead of silently corrupting it.
    $reader = [IO.StreamReader]::new($Path, [Text.UTF8Encoding]::new($false, $true), $true)
    try { return $reader.ReadToEnd() }
    catch { throw "无法可靠读取配置文件编码，未修改原文件。请先将配置另存为 UTF-8：$Path" }
    finally { $reader.Dispose() }
}

function Write-HistoryToolFile {
    param([string]$Path, [string]$Content)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

