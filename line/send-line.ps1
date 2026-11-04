# Push a text message to the user's own LINE through the "AI小幫手" official account.
# Token and user ID live outside this repo in %USERPROFILE%\.line-helper so they never get committed.
#
# Usage:
#   .\send-line.ps1 -Text "hello"
#   .\send-line.ps1 -TextFile .\post.txt
#   .\send-line.ps1 -TextFile .\post.txt -ImageUrl https://.../card.jpg -PreviewUrl https://.../preview.jpg
#   .\send-line.ps1 -ImageUrl a.jpg,b.jpg,c.jpg -PreviewUrl a-p.jpg,b-p.jpg,c-p.jpg
# LINE only takes images by public https URL (preview must be under 1 MB); images are sent before the text,
# at most 5 messages per push.
param(
    [string]$Text,
    [string]$TextFile,
    [string[]]$ImageUrl,
    [string[]]$PreviewUrl
)

$ErrorActionPreference = 'Stop'
$configDir = Join-Path $env:USERPROFILE '.line-helper'
$token = if ($env:LINE_CHANNEL_TOKEN) { $env:LINE_CHANNEL_TOKEN.Trim() } else { (Get-Content -Raw (Join-Path $configDir 'token.txt')).Trim() }
$userId = if ($env:LINE_USER_ID) { $env:LINE_USER_ID.Trim() } else { (Get-Content -Raw (Join-Path $configDir 'config.json') | ConvertFrom-Json).userId }

if (-not $token) { throw "token.txt is empty: paste the Channel access token into $configDir\token.txt" }
if ($TextFile) { $Text = Get-Content -Raw -Encoding UTF8 $TextFile }
if (-not $Text -and -not $ImageUrl) { throw 'Provide -Text, -TextFile or -ImageUrl' }

$messages = @()
for ($i = 0; $i -lt $ImageUrl.Count; $i++) {
    $preview = if ($PreviewUrl -and $PreviewUrl[$i]) { $PreviewUrl[$i] } else { $ImageUrl[$i] }
    $messages += @{ type = 'image'; originalContentUrl = $ImageUrl[$i]; previewImageUrl = $preview }
}
if ($Text) { $messages += @{ type = 'text'; text = $Text.Trim() } }
if ($messages.Count -gt 5) { throw 'LINE allows at most 5 messages per push' }

$body = @{
    to       = $userId
    messages = $messages
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Method Post -Uri 'https://api.line.me/v2/bot/message/push' `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null

Write-Output 'Sent'
