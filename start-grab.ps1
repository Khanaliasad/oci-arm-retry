# Starts grab-arm.sh as a hidden background process. Safe to run again: it won't start a second copy.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$running = Get-CimInstance Win32_Process -Filter "Name='bash.exe'" |
    Where-Object { $_.CommandLine -like '*grab-arm.sh*' }
if ($running) {
    Write-Host "Already running (pid $($running.ProcessId)). Log: $dir\provision.log"
    exit 0
}

# Make sure `oci` is found: add the folders where pip puts console scripts.
if (-not (Get-Command oci -ErrorAction SilentlyContinue) -and (Get-Command python -ErrorAction SilentlyContinue)) {
    foreach ($scheme in "nt", "nt_user") {
        $scripts = & python -c "import sysconfig;print(sysconfig.get_path('scripts','$scheme'))"
        if ($scripts) { $env:PATH += ";$scripts" }
    }
}
$env:OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING = "True"
$env:SUPPRESS_LABEL_WARNING = "True"

# Use Git for Windows' bash (not WSL's bash.exe in System32).
$bash = Join-Path $env:ProgramFiles "Git\usr\bin\bash.exe"
if (-not (Test-Path $bash)) { Write-Error "Git for Windows bash not found at $bash"; exit 1 }
$unixDir = (& $bash -lc "cygpath -u '$dir'").Trim()
$p = Start-Process -FilePath $bash -ArgumentList "-lc", "'cd $unixDir && ./grab-arm.sh >> provision.log 2>&1'" -WindowStyle Hidden -PassThru
Write-Host "Started (pid $($p.Id)). Watch it with:"
Write-Host "  Get-Content `"$dir\provision.log`" -Tail 10 -Wait"
