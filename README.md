# PowerShell 历史命令工具 1.0.0

按 **Ctrl+H** 打开历史命令窗口。默认显示最近 1000 条不同命令，可通过按钮切换全部历史，支持搜索和双击选择。选中的命令只填回输入行，按回车后才执行。

从 [GitHub Releases](https://github.com/mianmianlingqi/powershell-history-tool/releases/latest) 下载 `PowerShellHistoryTool-1.0.0.zip` 即可取得完整安装包。旁附 `.sha256` 文件可用于核对 ZIP 的 SHA256 校验值。

## 运行要求

- Windows 10 或 Windows 11。
- PowerShell 7.4 或更高版本，命令为 `pwsh`。Windows 自带的 Windows PowerShell 5.1 不适用。
- PSReadLine 2.4.5 或更高版本。安装脚本会检查依赖，不会自动联网安装软件。
- 使用 PowerShell 的控制台窗口，例如 Windows Terminal 中的 PowerShell 标签页。

如果缺少符合要求的 PSReadLine，可以自行联网安装到当前用户目录，然后重新打开 PowerShell：

```powershell
Install-Module PSReadLine -MinimumVersion 2.4.5 -Scope CurrentUser -Force
```

## 安装

1. 完整解压 ZIP 包到任意目录。
2. 在 PowerShell 7 中进入解压目录，执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

该命令的执行策略设置仅对这次安装进程有效。组织策略可能仍限制脚本运行。工具不需要管理员权限，不修改系统执行策略。

安装后新开 PowerShell 标签页，按 **Ctrl+H**。已有标签页可以执行 `. "$PROFILE"` 启用。若下载的 ZIP 被 Windows 标记为来自网络，可先在文件属性中解除锁定，再解压。

程序安装在当前用户 `%LOCALAPPDATA%\Programs\PowerShellHistoryTool`。安装脚本只在 `$PROFILE.CurrentUserCurrentHost` 添加带有 `PowerShellHistoryTool` 标记的加载区块，并备份已有配置；重复安装会替换这个区块。安装完成后可以删除解压目录。

重复安装须使用同一个安装目录和配置文件。配置文件通过临时文件替换方式更新；若安装中断，处理导致失败的原因后可以再次运行安装程序。配置以 UTF-8 保存，备份保留原始文件。支持 UTF-8 及带 BOM 的 Unicode 配置；无法识别为这些编码的旧文件会被拒绝，请先手动另存为 UTF-8。

需要自定义位置时：

```powershell
.\Install.ps1 -InstallPath 'D:\Tools\PowerShellHistoryTool' -ProfilePath $PROFILE.CurrentUserCurrentHost
```

## 使用

| 控件 | 功能 |
|---|---|
| 最近 1000 条 | 按从新到旧顺序显示最近 1000 条不同命令 |
| 全部历史 | 加载全部归档中的不同命令 |
| 搜索框 | 在当前范围内按文字搜索，不区分大小写 |
| 填回输入行或双击命令 | 将原始命令放回 PowerShell 输入行 |
| 取消、Esc 或关闭窗口 | 保留原来的输入 |

Ctrl+H 原有的删除前一个字符功能会被历史窗口覆盖。Backspace 键仍可使用。原有自动建议的配置不会由安装程序修改。

## 保存规则和数据位置

第一次加载时导入仍存在的 PSReadLine 历史文件。以后在启用工具的 PowerShell 会话中，允许写入磁盘的命令会追加到：

```text
%LOCALAPPDATA%\PowerShell\HistoryArchive\commands.jsonl
```

归档不按时间或条数自动清理，实际容量受磁盘和内存约束。列表会去重，归档可保存重复记录。默认从文件尾部读取近期记录，点击全部历史时才读取完整文件。重新打开窗口可以读取其他已启用会话新追加的记录。

工具沿用已有 PSReadLine 历史过滤规则，默认规则判断为敏感的命令不会归档。这不是完整的机密检测机制，历史文件为明文，请按个人数据管理。旧历史文件中已经存在的内容会原样导入。工具不上传数据，不访问网络。

每台电脑、每个 Windows 用户分别保存自己的历史。本分发包不包含作者的历史记录、个人配置或密钥。迁移个人数据时可在关闭相关终端后自行备份归档文件；不要把个人归档加入程序分发包。

## 卸载

在解压目录运行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

或者运行安装目录中的 `Uninstall.ps1`。自定义安装目录时，需传入相同的 `-InstallPath` 参数。

卸载只移除标记区块和已知程序文件，保留历史归档、配置备份及其他文件。重新打开 PowerShell 后生效，不会恢复安装前整份配置并覆盖安装后新增的设置。

## 已有手动安装的用户

如果此前已手动在配置中加载同一工具，请先移除旧的 `Scripts\RecentCommandHistory.ps1` 加载行，再运行安装程序。安装程序不会删除未知的旧配置。保留相同的默认归档路径可以继续使用原有历史。

## 包内容

- `Install.ps1`：当前用户安装程序。
- `Uninstall.ps1`：卸载程序，保留历史数据。
- `SetupHelpers.ps1`：配置读取和文件写入辅助函数。
- `Runtime/RecentCommandHistory.ps1`：工具完整源码。
- `README.md`：本说明。
- `SHA256SUMS.txt`：包内程序和说明文件的校验值。

此包可复制、分发和修改，按现状提供。
