<#
server.ps1
A small local HTTP server using System.Net.HttpListener.
Features:
- Bind starting from `-StartPort` with fallback attempts.
- Serve files from a specified drive (e.g. Q:). 
- Return simple directory listing HTML for folders.
- Generate `index.json` on-the-fly when requested.
- Spawn a detached `watcher.ps1` to cleanup `subst` mapping after this server exits.
#>

param(
	[int]$StartPort = 8080,
	[string]$Drive = 'Q:'
)

function Get-ContentType {
	param([string]$path)
	switch -Regex ([System.IO.Path]::GetExtension($path).ToLower()) {
		'\.html$' { 'text/html; charset=utf-8' ; return }
		'\.json$' { 'application/json; charset=utf-8' ; return }
		'\.md$'   { 'text/markdown; charset=utf-8' ; return }
		'\.css$'  { 'text/css; charset=utf-8' ; return }
		'\.js$'   { 'application/javascript; charset=utf-8' ; return }
		default   { 'application/octet-stream' ; return }
	}
}

function Try-BindPort {
	param([int]$port)
	try {
		$listener = New-Object System.Net.HttpListener
		$listener.Prefixes.Add("http://localhost:$port/")
		$listener.Start()
		return $listener
	} catch {
		return $null
	}
}

function Serve-DirectoryHtml {
	param(
		[System.Net.HttpListenerResponse]$res,
		[string]$dirPath,
		[string]$urlBase
	)
	try {
		$entries = Get-ChildItem -Path $dirPath -File | Sort-Object Name
		$escapedBase = [System.Web.HttpUtility]::HtmlEncode($urlBase)
		$html = "<html><head><meta charset='utf-8'><title>Index of $escapedBase</title></head><body><h1>Index of $escapedBase</h1><ul>"
		foreach ($e in $entries) {
			$name = [System.Web.HttpUtility]::HtmlEncode($e.Name)
			$href = [System.Uri]::EscapeUriString($e.Name)
			$html += "<li><a href='$href'>$name</a></li>"
		}
		$html += "</ul></body></html>"
		$bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
		$res.ContentType = 'text/html; charset=utf-8'
		$res.ContentLength64 = $bytes.Length
		$res.OutputStream.Write($bytes, 0, $bytes.Length)
	} catch {
		$res.StatusCode = 500
	} finally {
		$res.Close()
	}
}

function Serve-File {
	param(
		[System.Net.HttpListenerResponse]$res,
		[string]$filePath
	)
	try {
		$bytes = [System.IO.File]::ReadAllBytes($filePath)
		$res.ContentType = Get-ContentType -path $filePath
		$res.ContentLength64 = $bytes.Length
		$res.OutputStream.Write($bytes, 0, $bytes.Length)
	} catch {
		$res.StatusCode = 500
	} finally {
		$res.Close()
	}
}

function Generate-IndexJson {
	param([string]$dirPath)
	try {
		$items = Get-ChildItem -Path $dirPath -File | Sort-Object Name | ForEach-Object { $_.Name }
		return $items | ConvertTo-Json -Depth 2
	} catch {
		return $null
	}
}

# --- config.json (edit password) ---
$script:EditConfig = $null
$configPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $configPath -PathType Leaf) {
	try {
		$script:EditConfig = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
	} catch {
		Write-Output "Failed to parse config.json: $($_.Exception.Message)"
		$script:EditConfig = $null
	}
}

function Test-EditPassword {
	param([System.Net.HttpListenerRequest]$req)
	if (-not $script:EditConfig -or -not $script:EditConfig.editPassword) { return $false }
	$supplied = $req.Headers['X-Edit-Password']
	if ([string]::IsNullOrEmpty($supplied)) { return $false }
	return ($supplied -ceq [string]$script:EditConfig.editPassword)
}

# 安全なファイル名か検証する（Profile 配下の .md ファイル向け）。パス区切り・親ディレクトリ参照・先頭ドットを拒否する。
function Test-SafeMdFileName {
	param([string]$name)
	if ([string]::IsNullOrWhiteSpace($name)) { return $false }
	if ($name -match '[\\/]') { return $false }
	if ($name -match '\.\.') { return $false }
	if ($name.StartsWith('.')) { return $false }
	if ($name -notmatch '\.md$') { return $false }
	return $true
}

# 写真アップロード用のファイル名を無害化する（パス区切り・親ディレクトリ参照・先頭ドットを除去）。
function Get-SanitizedPhotoFileName {
	param([string]$name)
	if ([string]::IsNullOrWhiteSpace($name)) { return $null }
	$n = [string]$name
	$n = $n -replace '[\\/]', ''
	while ($n -match '\.\.') { $n = $n -replace '\.\.', '' }
	$n = $n.TrimStart('.')
	$n = $n.Trim()
	if ([string]::IsNullOrWhiteSpace($n)) { return $null }
	return $n
}

# メンバーの Markdown 本文から '## 写真' セクションの値（ファイル名）を抽出する。
# クライアント側の parseMarkdownToData と同様に、見出し直後の最初の非空行を値とみなす。
function Get-PhotoFileNameFromMarkdown {
	param([string]$content)
	if ([string]::IsNullOrEmpty($content)) { return $null }
	# 注意: '写真' をリテラルでソースに埋め込むと、Windows PowerShell 5.1 は BOM の無い .ps1 を
	# システムの既定コードページ（日本語環境では Shift_JIS 等）で読み込むため、非 ASCII 文字が
	# 文字化けして実行時に一致しなくなる。そのため \uXXXX エスケープ（写=U+5199, 真=U+771F）で
	# コードポイントを直接指定し、ソースファイルのエンコーディングに依存しないようにする。
	$m = [regex]::Match($content, ('(?ms)^##[ \t]*\u' + '5199\u' + '771f[ \t]*\r?\n(.*?)(?=\r?\n##[ \t]|\z)'))
	if (-not $m.Success) { return $null }
	$lines = $m.Groups[1].Value -split '\r?\n'
	foreach ($line in $lines) {
		if (-not [string]::IsNullOrWhiteSpace($line)) { return $line.Trim() }
	}
	return $null
}

function Write-JsonResponse {
	param(
		[System.Net.HttpListenerResponse]$res,
		[int]$statusCode,
		$obj
	)
	try {
		$json = $obj | ConvertTo-Json -Depth 10 -Compress
		$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
		$res.StatusCode = $statusCode
		$res.ContentType = 'application/json; charset=utf-8'
		$res.ContentLength64 = $bytes.Length
		$res.OutputStream.Write($bytes, 0, $bytes.Length)
	} catch {
		# best-effort; if writing fails there's nothing more we can do
	} finally {
		$res.Close()
	}
}

function Read-RequestBodyString {
	param([System.Net.HttpListenerRequest]$req)
	# 常に UTF-8 として読む。$req.ContentEncoding はブラウザの fetch() が Content-Type に
	# charset を付けない場合にシステムの既定コードページ（日本語環境では Shift_JIS 等）へ
	# フォールバックすることがあり、日本語本文が文字化けする原因になるため使用しない。
	# このサーバの API は常に UTF-8 の JSON を受け取る想定。
	$reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
	try {
		return $reader.ReadToEnd()
	} finally {
		$reader.Close()
	}
}

function Read-RequestBodyBytes {
	param([System.Net.HttpListenerRequest]$req)
	$ms = New-Object System.IO.MemoryStream
	try {
		$req.InputStream.CopyTo($ms)
		return $ms.ToArray()
	} finally {
		$ms.Close()
	}
}

# --- bind listener with fallback ---
$maxAttempts = 20
$listener = $null
$boundPort = $StartPort
for ($i = 0; $i -lt $maxAttempts; $i++) {
	$p = $StartPort + $i
	$listener = Try-BindPort -port $p
	if ($listener) { $boundPort = $p; break }
}

if (-not $listener) {
	Write-Error "Failed to bind any port starting at $StartPort"
	exit 1
}

Write-Output "Listening on http://localhost:$boundPort/"
# open root URL (server will serve index.html if present) to reduce duplicate index.html loads
Start-Process "http://localhost:$boundPort/"

# spawn detached watcher to cleanup subst mapping after server exits
try {
	$watcherPath = Join-Path $PSScriptRoot 'watcher.ps1'
	$watcherArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$watcherPath,'-ParentPid',$PID,'-Drive',$Drive)
	Start-Process -FilePath powershell -ArgumentList $watcherArgs -WindowStyle Hidden -WorkingDirectory $PSScriptRoot | Out-Null
} catch {
	# ignore watcher spawn failures
}

# --- main loop ---
while ($listener.IsListening) {
	try {
		$context = $listener.GetContext()
	} catch {
		break
	}

	$req = $context.Request
	$res = $context.Response
	# Log incoming request for debugging duplicate loads
	try {
		$remote = $req.RemoteEndPoint.ToString()
	} catch {
		$remote = 'unknown'
	}
	Write-Output "[$(Get-Date -Format o)] REQUEST: $($req.HttpMethod) $($req.Url.AbsolutePath) from $remote"

	$rawPath = $req.Url.LocalPath
	$decodedPath = [System.Uri]::UnescapeDataString($rawPath).TrimStart('/')
	$fsPath = Join-Path "$Drive\" $decodedPath

	# --- API routes (members CRUD + photo upload) ---
	$apiHandled = $false
	$absPath = $req.Url.AbsolutePath

	if ($absPath -eq '/api/members' -and $req.HttpMethod -eq 'POST') {
		$apiHandled = $true
		if (-not (Test-EditPassword -req $req)) {
			Write-JsonResponse -res $res -statusCode 401 -obj @{ error = 'invalid or missing edit password' }
		} else {
			try {
				$bodyStr = Read-RequestBodyString -req $req
				$payload = $bodyStr | ConvertFrom-Json
				$file = [string]$payload.file
				$content = [string]$payload.content
				if (-not (Test-SafeMdFileName -name $file)) {
					Write-JsonResponse -res $res -statusCode 400 -obj @{ error = 'invalid filename' }
				} else {
					$profileDir = Join-Path "$Drive\" 'Profile'
					if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
					$target = Join-Path $profileDir $file
					if (Test-Path $target -PathType Leaf) {
						Write-JsonResponse -res $res -statusCode 409 -obj @{ error = 'file already exists' }
					} else {
						[System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding($false)))
						Write-JsonResponse -res $res -statusCode 200 -obj @{ file = $file }
					}
				}
			} catch {
				Write-JsonResponse -res $res -statusCode 400 -obj @{ error = "bad request: $($_.Exception.Message)" }
			}
		}
	}
	elseif ($absPath -match '^/api/members/(.+)$' -and ($req.HttpMethod -eq 'PUT' -or $req.HttpMethod -eq 'DELETE')) {
		$apiHandled = $true
		$fileParam = [System.Uri]::UnescapeDataString($Matches[1])
		if (-not (Test-EditPassword -req $req)) {
			Write-JsonResponse -res $res -statusCode 401 -obj @{ error = 'invalid or missing edit password' }
		} elseif (-not (Test-SafeMdFileName -name $fileParam)) {
			Write-JsonResponse -res $res -statusCode 400 -obj @{ error = 'invalid filename' }
		} else {
			$profileDir = Join-Path "$Drive\" 'Profile'
			$target = Join-Path $profileDir $fileParam
			if (-not (Test-Path $target -PathType Leaf)) {
				Write-JsonResponse -res $res -statusCode 404 -obj @{ error = 'not found' }
			} elseif ($req.HttpMethod -eq 'PUT') {
				try {
					$bodyStr = Read-RequestBodyString -req $req
					$payload = $bodyStr | ConvertFrom-Json
					$content = [string]$payload.content
					[System.IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding($false)))
					Write-JsonResponse -res $res -statusCode 200 -obj @{ file = $fileParam }
				} catch {
					Write-JsonResponse -res $res -statusCode 400 -obj @{ error = "bad request: $($_.Exception.Message)" }
				}
			} else {
				try {
					# 削除前に写真ファイル名を読み取っておく（.md 削除後にクリーンアップするため）
					$mdContentForDelete = $null
					try { $mdContentForDelete = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8) } catch { $mdContentForDelete = $null }
					Remove-Item -Path $target -Force
					# 関連する写真ファイルもベストエフォートで削除する（default.jpg は共有フォールバックのため対象外。失敗してもメンバー削除自体は成功扱い）
					try {
						$photoName = Get-PhotoFileNameFromMarkdown -content $mdContentForDelete
						if ($photoName) {
							$safePhotoName = Get-SanitizedPhotoFileName -name $photoName
							if ($safePhotoName -and -not ($safePhotoName -ieq 'default.jpg')) {
								$photoDir = Join-Path "$Drive\" 'Profile\photo'
								$photoTarget = Join-Path $photoDir $safePhotoName
								if (Test-Path $photoTarget -PathType Leaf) {
									Remove-Item -Path $photoTarget -Force -ErrorAction SilentlyContinue
								}
							}
						}
					} catch {
						# 写真クリーンアップの失敗は無視する（ベストエフォート）
					}
					Write-JsonResponse -res $res -statusCode 200 -obj @{ file = $fileParam }
				} catch {
					Write-JsonResponse -res $res -statusCode 500 -obj @{ error = $_.Exception.Message }
				}
			}
		}
	}
	elseif ($absPath -eq '/api/photos' -and $req.HttpMethod -eq 'POST') {
		$apiHandled = $true
		if (-not (Test-EditPassword -req $req)) {
			Write-JsonResponse -res $res -statusCode 401 -obj @{ error = 'invalid or missing edit password' }
		} else {
			$rawName = $req.Headers['X-File-Name']
			$safeName = Get-SanitizedPhotoFileName -name $rawName
			if (-not $safeName) {
				Write-JsonResponse -res $res -statusCode 400 -obj @{ error = 'invalid or missing X-File-Name header' }
			} else {
				try {
					$bytes = Read-RequestBodyBytes -req $req
					$photoDir = Join-Path "$Drive\" 'Profile\photo'
					if (-not (Test-Path $photoDir)) { New-Item -ItemType Directory -Path $photoDir -Force | Out-Null }
					$target = Join-Path $photoDir $safeName
					[System.IO.File]::WriteAllBytes($target, $bytes)
					Write-JsonResponse -res $res -statusCode 200 -obj @{ filename = $safeName }
				} catch {
					Write-JsonResponse -res $res -statusCode 500 -obj @{ error = $_.Exception.Message }
				}
			}
		}
	}

	if ($apiHandled) { continue }

	# directory request: if index.html exists in the directory, serve it (avoid double-load from / and /index.html)
	if ($rawPath.EndsWith('/') -or (Test-Path $fsPath -PathType Container)) {
		if (-not (Test-Path $fsPath)) {
			$res.StatusCode = 404
			$res.Close()
			continue
		}
		$indexFile = Join-Path $fsPath 'index.html'
		if (Test-Path $indexFile -PathType Leaf) {
			Write-Output "[$(Get-Date -Format o)] Serving index.html for directory $fsPath"
			Serve-File -res $res -filePath $indexFile
			continue
		}
		Serve-DirectoryHtml -res $res -dirPath $fsPath -urlBase $rawPath
		continue
	}

	# serve file if exists
	if (Test-Path $fsPath -PathType Leaf) {
		Serve-File -res $res -filePath $fsPath
		continue
	}

	# if index.json requested, try generate
	if ($decodedPath -match '/?([^/]+/)*index\.json$' -or $decodedPath -ieq 'index.json') {
		$parent = Split-Path $fsPath -Parent
		if (Test-Path $parent) {
			$json = Generate-IndexJson -dirPath $parent
			if ($json -ne $null) {
				$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
				$res.ContentType = 'application/json; charset=utf-8'
				$res.ContentLength64 = $bytes.Length
				$res.OutputStream.Write($bytes, 0, $bytes.Length)
				$res.Close()
				continue
			}
		}
	}

	# not found
	$res.StatusCode = 404
	$res.Close()
}

$listener.Stop()
$listener.Close()

