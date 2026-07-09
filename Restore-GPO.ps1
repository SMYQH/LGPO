<#
.SYNOPSIS
    使用 LGPO.exe 从备份目录恢复本地组策略

.DESCRIPTION
    此脚本利用微软官方工具 LGPO.exe 将指定备份目录中的组策略恢复到本机。
    恢复前会自动备份当前策略，以便失败时回滚（备份存放于独立目录）。
    支持非交互模式（适合计划任务等自动化场景）。

.PARAMETER BackupPath
    组策略备份所在的目录（必须包含有效的 GUID 子文件夹），默认值为脚本所在目录下的 GPO_Backup 文件夹。

.PARAMETER LGPOExePath
    LGPO.exe 的完整路径，默认值为脚本所在目录下的 LGPO.exe。

.PARAMETER NonInteractive
    非交互模式。不显示任何提示，自动执行恢复。
    若备份路径无效或出现严重错误，脚本会直接终止并返回非零退出码。

.PARAMETER Force
    跳过所有确认提示（即使在交互模式下）。与非交互模式结合使用无需额外操作。

.EXAMPLE
    .\Restore-GPO.ps1
    以交互方式恢复默认路径下的策略。

.EXAMPLE
    .\Restore-GPO.ps1 -BackupPath "C:\MyGPOBackup" -Force
    恢复指定路径的策略，无需手动确认。

.EXAMPLE
    .\Restore-GPO.ps1 -NonInteractive
    在计划任务中调用，自动恢复默认路径的策略。
#>

param(
    [string]$BackupPath = "$PSScriptRoot\GPO_Backup",
    [string]$LGPOExePath = "$PSScriptRoot\LGPO.exe",
    [switch]$NonInteractive,
    [switch]$Force
)

# 设置控制台编码，防止中文乱码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "   本地组策略恢复工具 (LGPO Restore)   " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 1. 检查是否以管理员身份运行
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "❌ 错误：此脚本必须以管理员身份运行！" -ForegroundColor Red
    Write-Host "   请右键点击 PowerShell 图标，选择“以管理员身份运行”。" -ForegroundColor Yellow
    if (-not $NonInteractive) { Read-Host "按 Enter 键退出" }
    exit 1
}

# 2. 检查 LGPO.exe 是否存在
if (-not (Test-Path $LGPOExePath)) {
    Write-Host "❌ 错误：找不到 LGPO.exe！" -ForegroundColor Red
    Write-Host "   请确保将此脚本与 LGPO.exe 放在同一目录下。" -ForegroundColor Yellow
    Write-Host "   当前查找路径: $LGPOExePath" -ForegroundColor Gray
    if (-not $NonInteractive) { Read-Host "按 Enter 键退出" }
    exit 1
}
Write-Host "✅ 找到 LGPO.exe: $LGPOExePath" -ForegroundColor Green

# 3. 检查备份路径是否存在
if (-not (Test-Path $BackupPath)) {
    Write-Host "❌ 错误：找不到备份文件夹！" -ForegroundColor Red
    Write-Host "   当前指定路径: $BackupPath" -ForegroundColor Yellow
    if (-not $NonInteractive) { Read-Host "按 Enter 键退出" }
    exit 1
}

# 检查备份文件夹内是否包含有效的 GUID 子文件夹（更精确的正则表达式）
$guidPattern = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'
$guidFolders = Get-ChildItem -Path $BackupPath -Directory | Where-Object { $_.Name -match $guidPattern }

if ($guidFolders.Count -eq 0) {
    Write-Host "⚠️ 警告：在备份路径下未找到 GUID 格式的子文件夹，可能不是有效的 GPO 备份。" -ForegroundColor Yellow
    Write-Host "   备份路径: $BackupPath" -ForegroundColor Gray
    if ($NonInteractive -or $Force) {
        Write-Host "非交互/强制模式，终止恢复以免误操作。请检查备份目录。" -ForegroundColor Red
        exit 1
    }
    $confirm = Read-Host "是否仍要继续恢复？(y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "已取消恢复操作。" -ForegroundColor Gray
        exit 0
    }
} else {
    Write-Host "✅ 找到备份文件夹: $BackupPath" -ForegroundColor Green
    Write-Host "   包含 $($guidFolders.Count) 个 GPO 备份：" -ForegroundColor Gray
    foreach ($f in $guidFolders) {
        Write-Host "   - $($f.Name)" -ForegroundColor Gray
    }
}

# 4. 恢复前备份当前策略（回滚保障）—— 存放在独立目录，避免污染备份源
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$rollbackRoot = "$env:TEMP\GPO_Rollback"
if (-not (Test-Path $rollbackRoot)) {
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
}
$preRestoreBackup = Join-Path $rollbackRoot "PreRestore_$timestamp"
Write-Host "`n🔄 正在备份当前组策略到: $preRestoreBackup" -ForegroundColor Cyan

# LGPO.exe /b 要求目标目录必须存在，且不能是已有备份的目录（它会自动创建 GUID 子目录）
# 直接使用 $preRestoreBackup 作为父目录，确保它存在
if (-not (Test-Path $preRestoreBackup)) {
    New-Item -ItemType Directory -Path $preRestoreBackup -Force | Out-Null
}

& $LGPOExePath /b "$preRestoreBackup" 2>&1 | Out-Null   # 静默执行，只看退出码
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ 当前策略备份失败（错误代码: $LASTEXITCODE），终止恢复操作！" -ForegroundColor Red
    Write-Host "   请检查 LGPO.exe 是否可正常执行，或是否有权限写入 $rollbackRoot" -ForegroundColor Yellow
    if (-not $NonInteractive) { Read-Host "按 Enter 键退出" }
    exit 1
}
Write-Host "✅ 当前策略备份完成。回滚备份路径: $preRestoreBackup" -ForegroundColor Green

# 5. 确认恢复操作（可根据参数跳过）
if (-not ($NonInteractive -or $Force)) {
    Write-Host ""
    Write-Host "⚠️ 即将执行恢复操作：将备份的策略应用到本机！" -ForegroundColor Yellow
    $confirm = Read-Host "确认继续？(y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "已取消恢复操作。当前策略备份保留在: $preRestoreBackup" -ForegroundColor Gray
        exit 0
    }
}

# 6. 执行恢复并记录日志（日志也放在独立目录，避免污染备份源）
$logDir = "$PSScriptRoot\Logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logFile = Join-Path $logDir "restore_$timestamp.log"
Write-Host "`n🔄 正在恢复组策略，日志将保存至: $logFile" -ForegroundColor Cyan

# 使用 Tee-Object 同时显示输出和写入日志
& $LGPOExePath /g "$BackupPath" 2>&1 | Tee-Object -FilePath $logFile

# 7. 检查恢复结果
if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ 策略文件恢复成功！" -ForegroundColor Green

    Write-Host "`n🔄 正在强制刷新组策略 (gpupdate /force)..." -ForegroundColor Cyan
    gpupdate /force

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ 组策略刷新完成！" -ForegroundColor Green
    } else {
        Write-Host "⚠️ gpupdate 执行可能遇到问题，但策略文件已恢复。" -ForegroundColor Yellow
        Write-Host "   建议重启电脑让策略完全生效。" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "🎉 恢复流程全部完成！" -ForegroundColor Green
    Write-Host "📌 建议：重启电脑以确保所有策略设置完全生效。" -ForegroundColor Yellow
    Write-Host "📄 恢复日志: $logFile" -ForegroundColor Gray
    Write-Host "🔄 回滚备份: $preRestoreBackup" -ForegroundColor Gray
    Write-Host "========================================" -ForegroundColor Cyan
} else {
    Write-Host "❌ 策略恢复失败！错误代码: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "   请检查 LGPO.exe 的输出信息，或确认备份文件是否损坏。" -ForegroundColor Yellow
    Write-Host "💡 提示：如需回滚，可使用当前策略备份：" -ForegroundColor Yellow
    Write-Host "   LGPO.exe /g `"$preRestoreBackup`"" -ForegroundColor Gray
}

Write-Host ""
if (-not $NonInteractive) { Read-Host "按 Enter 键退出" }

# 返回与 LGPO 执行结果一致的退出码
exit $LASTEXITCODE