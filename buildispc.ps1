param(
    [string] $LLVM_VERSION="5.0"
)

$env:ISPC_HOME=Get-Location
$env:LLVM_HOME="./llvm-build"
$env:Z3_LIBRARIES="../z3-4.8.4.d6df51951f4c-x64-win/bin/"
$env:Z3_INCLUDE_DIR="../z3-4.8.4.d6df51951f4c-x64-win/include/"

py ./alloy.py -b --version="$LLVM_VERSION" --selfbuild --git

$env:Path += ";$LLVM_HOME/build-$LLVM_VERSION/bin"
cd build-5.0
cmake -G "Visual Studio 15 2017" -DCMAKE_INSTALL_PREFIX=..\bin-5.0\ -DCMAKE_BUILD_TYPE=Release ..
