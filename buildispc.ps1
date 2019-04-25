param(
    [string] $LLVM_VERSION="5.0"
)

$env:ISPC_HOME=Get-Location
$env:LLVM_HOME="./llvm-build"

py ./alloy.py -b --version="$LLVM_VERSION" --selfbuild --git

$env:Path += ";$LLVM_HOME/build-$LLVM_VERSION/bin"
cd build-5.0
cmake -G "Visual Studio 15 2017" -DCMAKE_INSTALL_PREFIX=..\bin-5.0\ -DCMAKE_BUILD_TYPE=Release ..
