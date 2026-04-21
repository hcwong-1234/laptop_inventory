$mysqlBin = "C:\Program Files\MySQL\MySQL Server 8.4\bin"

# Read current Machine PATH
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")

# If it's not already there, append it
if ($machinePath -notlike "*$mysqlBin*") {
    [Environment]::SetEnvironmentVariable(
        "Path",
        "$machinePath;$mysqlBin",
        "Machine"
    )
}

# Also update PATH for THIS PowerShell session immediately
$env:Path = "$env:Path;$mysqlBin"
