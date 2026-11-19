# spark installer for Windows.
#
#   irm https://raw.githubusercontent.com/NZ-Linix/spark/main/install.ps1 | iex
#
# spark runs on macOS and Linux. On Windows it runs inside WSL, so this
# script checks for WSL and runs the Linux installer (install.sh) there.
#
# Environment: SPARK_REPO, SPARK_VERSION, SPARK_WSL_DISTRO (a WSL distro to
# use instead of the default), SPARK_INSTALL_ARGS (extra install.sh options),
# NO_COLOR.

& {
	$ErrorActionPreference = 'Stop'
	Set-StrictMode -Version 2

	$Repo = if ($env:SPARK_REPO) { $env:SPARK_REPO } else { 'NZ-Linix/spark' }
	$ScriptUrl = "https://raw.githubusercontent.com/$Repo/main/install.sh"

	# ── terminal ──────────────────────────────────────────────────────────

	$Vt = $false
	try { $Vt = [bool]$Host.UI.SupportsVirtualTerminal } catch { }
	$Interactive = $Vt -and -not [Console]::IsOutputRedirected
	$Color = $Vt -and -not $env:NO_COLOR
	$E = [char]27
	if ($Color) {
		$R = "$E[0m"; $Bright = "$E[1;97m"; $White = "$E[0;37m"
		$Gray = "$E[38;5;245m"; $Faint = "$E[38;5;240m"; $Red = "$E[1;31m"; $Yellow = "$E[33m"
	} else {
		$R = ''; $Bright = ''; $White = ''; $Gray = ''; $Faint = ''; $Red = ''; $Yellow = ''
	}
	$ClearLine = if ($Vt) { "$E[2K" } else { '' }

	$Unicode = $Vt -and [Console]::OutputEncoding.CodePage -eq 65001
	if (-not $Unicode -and $Vt) {
		try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $Unicode = $true } catch { }
	}
	if ($Unicode) {
		$Star = [string][char]0x2726; $Twinkle = [string][char]0x2727; $Dot = [string][char]0x00B7
		$Check = [string][char]0x2713; $Cross = [string][char]0x2717
	} else {
		$Star = '*'; $Twinkle = '+'; $Dot = '.'; $Check = '+'; $Cross = 'x'
	}

	function Write-Raw([string]$Text) { [Console]::Write($Text) }

	function Get-Streak([int]$Width, [int]$Head, [int]$Seed) {
		$sb = [Text.StringBuilder]::new()
		for ($c = 0; $c -lt $Width; $c++) {
			if ($c -eq $Head) { [void]$sb.Append("$Bright$Star") }
			elseif ($c -eq $Head - 1) { [void]$sb.Append("$White=") }
			elseif ($c -eq $Head - 2) { [void]$sb.Append("$Gray-") }
			elseif ((($c * 7 + $Seed) % 11) -eq 0) { [void]$sb.Append("$Gray$Twinkle") }
			else { [void]$sb.Append("$Faint$Dot") }
		}
		[void]$sb.Append($R)
		$sb.ToString()
	}

	function Invoke-Sweep([int]$Width) {
		if (-not $Interactive) { return }
		Write-Raw "$E[?25l"
		for ($h = 0; $h -le $Width + 2; $h++) {
			Write-Raw ("`r$ClearLine  " + (Get-Streak $Width $h $h))
			Start-Sleep -Milliseconds 12
		}
		Write-Raw "`r$ClearLine$E[?25h"
	}

	function Write-Done([string]$Label, [string]$Detail = '') {
		$line = "  $Bright$Check$R  $Label"
		if ($Detail) { $line += "  $Gray$Detail$R" }
		Write-Raw "$line`n"
	}

	function Stop-Install([string]$Message, [string[]]$Notes = @()) {
		Write-Raw "`n  $Red$Cross$R  $Message`n"
		foreach ($n in $Notes) { Write-Raw "     $Gray$n$R`n" }
		Write-Raw "`n"
		throw [Management.Automation.RuntimeException]::new('spark-install-stopped')
	}

	# Run-Step LABEL SCRIPTBLOCK: runs the block as a background job with
	# the comet beside LABEL. Returns the block's output.
	function Invoke-Step([string]$Label, [scriptblock]$Block, [object[]]$Arguments = @()) {
		$job = Start-Job -ScriptBlock $Block -ArgumentList $Arguments
		$tick = 0
		$watch = [Diagnostics.Stopwatch]::StartNew()
		if ($Interactive) { Write-Raw "$E[?25l" }
		while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
			if ($Interactive) {
				$secs = [int]$watch.Elapsed.TotalSeconds
				$elapsed = if ($secs -ge 3) { "  $Gray${secs}s$R" } else { '' }
				Write-Raw ("`r$ClearLine  $Gray$Star$R  $Label  " + (Get-Streak 14 ($tick % 18) ([int]($tick / 3))) + $elapsed)
				$tick++
			}
			Start-Sleep -Milliseconds 50
		}
		if ($Interactive) { Write-Raw "`r$ClearLine$E[?25h" }
		try {
			$out = Receive-Job $job -ErrorAction Stop
		} catch {
			Remove-Job $job -Force
			Write-Raw "  $Red$Cross$R  $Label`n"
			Stop-Install $_.Exception.Message
		}
		Remove-Job $job -Force
		return $out
	}

	# ── header ────────────────────────────────────────────────────────────

	$Logo = @(
		'                      _',
		' ___ _ __   __ _ _ __| | __',
		'/ __| ''_ \ / _` | ''__| |/ /',
		'\__ \ |_) | (_| | |  |   <',
		'|___/ .__/ \__,_|_|  |_|\_\',
		'    |_|'
	)

	try {
		Write-Raw "`n"
		if ($Interactive) { Write-Raw "$E[?25l" }
		foreach ($line in $Logo) {
			Write-Raw "  $Bright$line$R`n"
			if ($Interactive) { Start-Sleep -Milliseconds 40 }
		}
		Invoke-Sweep 27
		Write-Raw "  $White-=$Bright$Star$R ${Gray}installer$R`n`n"

		# ── WSL ───────────────────────────────────────────────────────────

		if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
			Stop-Install 'spark runs on macOS and Linux. On Windows it runs inside WSL.' @(
				'Install WSL from an administrator PowerShell, then restart:',
				'  wsl --install',
				'Then run this installer again.'
			)
		}

		$distroArgs = @()
		if ($env:SPARK_WSL_DISTRO) { $distroArgs = @('-d', $env:SPARK_WSL_DISTRO) }

		$probe = Invoke-Step 'Checking WSL' {
			param($DistroArgs)
			$out = & wsl.exe @DistroArgs -e sh -c 'printf "%s %s" "$(uname -m)" "$(. /etc/os-release 2>/dev/null; printf %s "${PRETTY_NAME:-Linux}")"' 2>&1
			if ($LASTEXITCODE -ne 0) { throw 'WSL has no Linux distribution yet. Run: wsl --install -d Ubuntu' }
			($out | Out-String).Trim()
		} -Arguments (, $distroArgs)

		if (-not $probe) {
			Stop-Install 'WSL did not answer.' @('Open WSL once to finish its setup, then run this installer again.')
		}
		$parts = $probe -split ' ', 2
		Write-Done "WSL" ($parts[1] + '  ' + $parts[0])

		$hasCurl = & wsl.exe @distroArgs -e sh -c 'command -v curl >/dev/null && echo yes' 2>$null
		if (-not $hasCurl) {
			Stop-Install 'curl is not installed in WSL.' @('In WSL run: sudo apt install curl', 'Then run this installer again.')
		}

		# install.sh continues the same list of steps below; it skips its
		# own header because this one is already on screen.
		$extra = @()
		if ($env:SPARK_VERSION) { $extra += @('--version', $env:SPARK_VERSION) }
		if ($env:SPARK_INSTALL_ARGS) { $extra += ($env:SPARK_INSTALL_ARGS -split '\s+' | Where-Object { $_ }) }
		$quoted = ($extra | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
		$envPrefix = "SPARK_INSTALLER_NESTED=1 "
		if ($env:SPARK_REPO) { $envPrefix += "SPARK_REPO='$Repo' " }
		$cmd = "curl -fsSL '$ScriptUrl' | ${envPrefix}sh -s -- $quoted"

		& wsl.exe @distroArgs -e sh -c $cmd
		if ($LASTEXITCODE -ne 0) {
			throw [Management.Automation.RuntimeException]::new('spark-install-stopped')
		}
		Write-Raw "  ${Gray}spark lives in WSL: open it with$R wsl$Gray, then run$R spark$Gray.$R`n`n"
	} catch {
		if ($Interactive) { Write-Raw "$E[?25h" }
		if ($_.Exception.Message -ne 'spark-install-stopped') {
			Write-Raw "`n  $Red$Cross$R  $($_.Exception.Message)`n`n"
		}
	}
}
