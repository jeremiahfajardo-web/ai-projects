param()

# Stop hook — if any Python file in a workspace Python repo was edited this
# session, remind the user to run the test suite. Reads the session marker
# created by lint-on-py-edit.ps1 and deletes it after firing once.

$markerPath = "c:/projects/ai-projects/.claude/.python-edited-this-session"

if (Test-Path $markerPath) {
    Remove-Item $markerPath -Force -ErrorAction SilentlyContinue
    $msg = "Python files were edited this session - run the run-tests skill before considering this done."
    $obj = [ordered]@{ systemMessage = $msg } | ConvertTo-Json -Compress
    Write-Output $obj
}

exit 0
