param(
  [int]$Port = 8000
)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Public = Join-Path $Root "public"
$Data = Join-Path $Root "data"
$DbPath = Join-Path $Data "db.json"

function Initialize-Db {
  if (!(Test-Path $Data)) { New-Item -ItemType Directory -Path $Data | Out-Null }
  if (!(Test-Path $DbPath)) {
    @{
      users = @()
      quizResults = @()
      feedback = @()
      demoBookings = @()
      students = @{ count = 428; history = @(280, 316, 352, 389, 428) }
    } | ConvertTo-Json -Depth 8 | Set-Content -Path $DbPath -Encoding UTF8
  }
}

function Read-Db {
  Initialize-Db
  return Get-Content -Path $DbPath -Raw | ConvertFrom-Json
}

function Write-Db($Db) {
  $Db | ConvertTo-Json -Depth 12 | Set-Content -Path $DbPath -Encoding UTF8
}

function Send-Text($Response, [int]$Status, [string]$Body, [string]$ContentType) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $Response.StatusCode = $Status
  $Response.ContentType = $ContentType
  $Response.Headers.Add("X-Content-Type-Options", "nosniff")
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Response.Close()
}

function Send-Json($Response, [int]$Status, $Body) {
  Send-Text $Response $Status ($Body | ConvertTo-Json -Depth 12) "application/json; charset=utf-8"
}

function Read-Body($Request) {
  $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
  $raw = $reader.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
  return $raw | ConvertFrom-Json
}

function Hash-Password([string]$Password, [string]$Salt = "") {
  if ([string]::IsNullOrWhiteSpace($Salt)) {
    $saltBytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($saltBytes)
    $rng.Dispose()
    $Salt = [Convert]::ToBase64String($saltBytes)
  }
  $saltBytes = [Convert]::FromBase64String($Salt)
  try {
    $pbkdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $saltBytes, 120000, [System.Security.Cryptography.HashAlgorithmName]::SHA512)
  } catch {
    $pbkdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $saltBytes, 120000)
  }
  return @{ salt = $Salt; hash = [Convert]::ToBase64String($pbkdf.GetBytes(64)) }
}

function Safe-User($User) {
  return @{ id = $User.id; name = $User.name; email = $User.email }
}

function Add-Item($Array, $Item) {
  $items = @($Array)
  $items += $Item
  return $items
}

function Handle-Api($Context) {
  $req = $Context.Request
  $res = $Context.Response
  $db = Read-Db

  if ($req.HttpMethod -eq "GET" -and $req.Url.AbsolutePath -eq "/api/stats") {
    $leaderboard = @($db.quizResults) | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "createdAt"; Descending = $true } | Select-Object -First 10
    $testimonials = @($db.feedback) | Where-Object { $_.rating -ge 4 } | Select-Object -Last 6
    Send-Json $res 200 @{ studentCount = ($db.students.count + @($db.users).Count); history = $db.students.history; leaderboard = $leaderboard; testimonials = $testimonials }
    return
  }

  if ($req.HttpMethod -eq "POST" -and $req.Url.AbsolutePath -eq "/api/signup") {
    $body = Read-Body $req
    $name = [string]$body.name
    $email = ([string]$body.email).Trim().ToLowerInvariant()
    $password = [string]$body.password
    $confirm = [string]$body.confirmPassword
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($email) -or $password.Length -lt 8 -or $password -ne $confirm) {
      Send-Json $res 400 @{ error = "Please provide a name, valid email, and matching password of at least 8 characters." }
      return
    }
    if (@($db.users) | Where-Object { $_.email -eq $email }) {
      Send-Json $res 409 @{ error = "An account already exists for this email." }
      return
    }
    $user = @{ id = [guid]::NewGuid().ToString(); name = $name.Trim(); email = $email; passwordHash = Hash-Password $password; createdAt = (Get-Date).ToUniversalTime().ToString("o") }
    $db.users = Add-Item $db.users $user
    Write-Db $db
    Send-Json $res 201 @{ user = Safe-User $user; redirect = "/welcome.html" }
    return
  }

  if ($req.HttpMethod -eq "POST" -and $req.Url.AbsolutePath -eq "/api/login") {
    $body = Read-Body $req
    $email = ([string]$body.email).Trim().ToLowerInvariant()
    $password = [string]$body.password
    $user = @($db.users) | Where-Object { $_.email -eq $email } | Select-Object -First 1
    if (!$user) { Send-Json $res 401 @{ error = "Invalid email or password." }; return }
    $attempt = Hash-Password $password $user.passwordHash.salt
    if ($attempt.hash -ne $user.passwordHash.hash) { Send-Json $res 401 @{ error = "Invalid email or password." }; return }
    Send-Json $res 200 @{ user = Safe-User $user; redirect = "/dashboard.html" }
    return
  }

  if ($req.HttpMethod -eq "POST" -and $req.Url.AbsolutePath -eq "/api/quiz-results") {
    $body = Read-Body $req
    $item = @{ id = [guid]::NewGuid().ToString(); name = [string]$body.name; subject = [string]$body.subject; score = [int]$body.score; total = [int]$body.total; createdAt = (Get-Date).ToUniversalTime().ToString("o") }
    $db.quizResults = Add-Item $db.quizResults $item
    Write-Db $db
    Send-Json $res 201 $item
    return
  }

  if ($req.HttpMethod -eq "POST" -and $req.Url.AbsolutePath -eq "/api/feedback") {
    $body = Read-Body $req
    $item = @{ id = [guid]::NewGuid().ToString(); name = [string]$body.name; role = [string]$body.role; rating = [int]$body.rating; comments = [string]$body.comments; createdAt = (Get-Date).ToUniversalTime().ToString("o") }
    $db.feedback = Add-Item $db.feedback $item
    Write-Db $db
    Send-Json $res 201 $item
    return
  }

  if ($req.HttpMethod -eq "POST" -and $req.Url.AbsolutePath -eq "/api/demo-booking") {
    $body = Read-Body $req
    $item = @{ id = [guid]::NewGuid().ToString(); name = [string]$body.name; email = [string]$body.email; subject = [string]$body.subject; slot = [string]$body.slot; createdAt = (Get-Date).ToUniversalTime().ToString("o") }
    $db.demoBookings = Add-Item $db.demoBookings $item
    Write-Db $db
    Send-Json $res 201 $item
    return
  }

  Send-Json $res 404 @{ error = "API route not found." }
}

function Serve-File($Context) {
  $path = [uri]::UnescapeDataString($Context.Request.Url.AbsolutePath)
  if ($path -eq "/") { $path = "/index.html" }
  $relative = $path.TrimStart("/")
  $file = Join-Path $Public $relative
  $resolved = [System.IO.Path]::GetFullPath($file)
  $publicResolved = [System.IO.Path]::GetFullPath($Public)
  if (!$resolved.StartsWith($publicResolved)) {
    Send-Text $Context.Response 403 "Forbidden" "text/plain; charset=utf-8"
    return
  }
  if (!(Test-Path $resolved -PathType Leaf)) {
    $notFound = Join-Path $Public "404.html"
    Send-Text $Context.Response 404 (Get-Content -Path $notFound -Raw) "text/html; charset=utf-8"
    return
  }
  $types = @{ ".html" = "text/html; charset=utf-8"; ".css" = "text/css; charset=utf-8"; ".js" = "application/javascript; charset=utf-8"; ".pdf" = "application/pdf" }
  $ext = [System.IO.Path]::GetExtension($resolved)
  $bytes = [System.IO.File]::ReadAllBytes($resolved)
  $Context.Response.StatusCode = 200
  $Context.Response.ContentType = $types[$ext]
  if (!$Context.Response.ContentType) { $Context.Response.ContentType = "application/octet-stream" }
  $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Context.Response.Close()
}

Initialize-Db
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "Education site running at http://127.0.0.1:$Port"

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      if ($context.Request.Url.AbsolutePath.StartsWith("/api/")) {
        Handle-Api $context
      } else {
        Serve-File $context
      }
    } catch {
      try {
        Send-Json $context.Response 500 @{ error = $_.Exception.Message }
      } catch {
        $context.Response.Close()
      }
    }
  }
} finally {
  $listener.Stop()
}
