$bytes = [Convert]::FromBase64String($input)
$decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
Write-Output $decoded