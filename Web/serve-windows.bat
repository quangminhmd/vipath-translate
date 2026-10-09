@echo off
REM ViPath Web cho Windows: bam dup tep nay (dat cung thu muc voi ViPath.html).
REM Mo qua may chu cuc bo http://localhost:8765 de Chrome giu mo hinh da tai va cho dung micro.
cd /d "%~dp0"
set PORT=8765
where py >nul 2>nul && (
  start "" "http://localhost:%PORT%/ViPath.html"
  py -m http.server %PORT% --bind 127.0.0.1
  goto :eof
)
where python >nul 2>nul && (
  start "" "http://localhost:%PORT%/ViPath.html"
  python -m http.server %PORT% --bind 127.0.0.1
  goto :eof
)
REM Khong co Python: dung may chu nho cua PowerShell (co san trong Windows)
start "" "http://localhost:%PORT%/ViPath.html"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$l=New-Object Net.HttpListener; $l.Prefixes.Add('http://localhost:%PORT%/'); $l.Start(); Write-Host 'ViPath Web dang chay tai http://localhost:%PORT%/ViPath.html  (dong cua so nay de dung)';" ^
  "while($l.IsListening){ $c=$l.GetContext(); $p=$c.Request.Url.LocalPath.TrimStart('/'); if($p -eq ''){$p='ViPath.html'}; $f=Join-Path (Get-Location) $p;" ^
  "if(Test-Path $f -PathType Leaf){ $b=[IO.File]::ReadAllBytes($f); if($f -like '*.html'){$c.Response.ContentType='text/html; charset=utf-8'}; $c.Response.OutputStream.Write($b,0,$b.Length) } else { $c.Response.StatusCode=404 }; $c.Response.Close() }"
