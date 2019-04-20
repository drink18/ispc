param(
    [string] $LLVM_VERSION="5.0"
)

$env:ISPC_HOME=Get-Location
$env:LLVM_HOME="llvm-bulid"


py ./alloy.py -b --version="$LLVM_VERSION" --selfbuild --git
