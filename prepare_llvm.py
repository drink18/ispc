import os
import common
import platform



global f_date
f_date = "logs"

global alloy_build
global alloy_folder

alloy_folder = os.getcwd() + os.sep + f_date + os.sep
alloy_build = alloy_folder + "alloy_build.log"

global current_OS
global current_OS_version
current_OS_version = platform.release()
if (platform.system() == 'Windows' or 'CYGWIN_NT' in platform.system()) == True:
    current_OS = "Windows"
else:
    if (platform.system() == 'Darwin'):
        current_OS = "MacOS"
    else:
        current_OS = "Linux" 



print_debug = common.print_debug
error = common.error

def make_sure_dir_exists(path):
    if not os.path.exists(path):
        os.makedirs(path)

# ISPC uses LLVM dumps for debug output, so build correctly it requires these functions to be
# present in LLVM libraries. In LLVM 5.0 they are not there by default and require explicit enabling.
# In later version this functionality is triggered by enabling assertions.
def get_llvm_enable_dump_switch(version_LLVM):
    if version_LLVM in ["3_2", "3_3", "3_4", "3_5", "3_6", "3_7", "3_8", "3_9", "4_0"]:
        return ""
    elif version_LLVM == "5_0":
        return " -DCMAKE_C_FLAGS=-DLLVM_ENABLE_DUMP -DCMAKE_CXX_FLAGS=-DLLVM_ENABLE_DUMP "
    else:
        return " -DLLVM_ENABLE_DUMP=ON "

def try_do_LLVM(text, command, from_validation):
    print_debug("Command line: "+command+"\n", True, alloy_build)
    print 'Command line : {}'.format(command)
    if from_validation == True:
        text = text + "\n"
    print_debug("Trying to " + text, from_validation, alloy_build)
    postfix = ""
    # if current_OS == "Windows":
        # postfix = " 1>> " + alloy_build + " 2>&1"
    # else:
        # postfix = " >> " + alloy_build + " 2>> " + alloy_build
    if os.system(command + postfix) != 0:
        print_debug("ERROR.\n", from_validation, alloy_build)
    print_debug("DONE.\n", from_validation, alloy_build)

def checkout_LLVM(component, use_git, version_LLVM, revision, target_dir, from_validation):
    # Identify the component
    GIT_REPO_BASE="http://llvm.org/git/"
    #GIT_REPO_BASE="https://github.com/llvm-mirror/"
    if component == "llvm":
        SVN_REPO="https://llvm.org/svn/llvm-project/llvm/"
        GIT_REPO=GIT_REPO_BASE+"llvm.git"
    elif component == "clang":
        SVN_REPO="https://llvm.org/svn/llvm-project/cfe/"
        GIT_REPO=GIT_REPO_BASE+"clang.git"
    elif component == "libcxx":
        SVN_REPO="https://llvm.org/svn/llvm-project/libcxx/"
        GIT_REPO=GIT_REPO_BASE+"libcxx.git"
    elif component == "clang-tools-extra":
        SVN_REPO="https://llvm.org/svn/llvm-project/clang-tools-extra/"
        GIT_REPO=GIT_REPO_BASE+"clang-tools-extra.git"
    elif component == "compiler-rt":
        SVN_REPO="https://llvm.org/svn/llvm-project/compiler-rt/"
        GIT_REPO=GIT_REPO_BASE+"compiler-rt.git"
    else:
        error("Trying to checkout unidentified component: " + component, 1)

    # Identify the version
    if  version_LLVM == "trunk":
        SVN_PATH="trunk"
        GIT_BRANCH="master"
    elif  version_LLVM == "8_0":
        SVN_PATH="tags/RELEASE_800/final"
        GIT_BRANCH="release_80"
    elif  version_LLVM == "7_0":
        SVN_PATH="tags/RELEASE_701/final"
        GIT_BRANCH="release_70"
    elif  version_LLVM == "6_0":
        SVN_PATH="tags/RELEASE_601/final"
        GIT_BRANCH="release_60"
    elif  version_LLVM == "5_0":
        SVN_PATH="tags/RELEASE_502/final"
        GIT_BRANCH="release_50"
    elif  version_LLVM == "4_0":
        SVN_PATH="tags/RELEASE_401/final"
        GIT_BRANCH="release_40"
    elif  version_LLVM == "3_9":
        SVN_PATH="tags/RELEASE_390/final"
        GIT_BRANCH="release_39"
    elif  version_LLVM == "3_8":
        SVN_PATH="tags/RELEASE_381/final"
        GIT_BRANCH="release_38"
    elif  version_LLVM == "3_7":
        SVN_PATH="tags/RELEASE_370/final"
        GIT_BRANCH="release_37"
    elif  version_LLVM == "3_6":
        SVN_PATH="tags/RELEASE_362/final"
        GIT_BRANCH="release_36"
    elif  version_LLVM == "3_5":
        SVN_PATH="tags/RELEASE_351/final"
        GIT_BRANCH="release_35"
    elif  version_LLVM == "3_4":
        SVN_PATH="tags/RELEASE_34/dot2-final"
        GIT_BRANCH="release_34"
    elif  version_LLVM == "3_3":
        SVN_PATH="tags/RELEASE_33/final"
        GIT_BRANCH="release_33"
    elif  version_LLVM == "3_2":
        SVN_PATH="tags/RELEASE_32/final"
        GIT_BRANCH="release_32"
    else:
        error("Unsupported llvm version: " + version_LLVM, 1)

    if use_git:
        try_do_LLVM("clone "+component+" from "+GIT_REPO+" to "+target_dir+" ",
                    "git clone "+GIT_REPO+" "+target_dir,
                    from_validation)
        if GIT_BRANCH != "master":
            os.chdir(target_dir)
            try_do_LLVM("switch to "+GIT_BRANCH+" branch ",
                        "git checkout -b "+GIT_BRANCH+" remotes/origin/"+GIT_BRANCH, from_validation)
            os.chdir("..")
    else:
        try_do_LLVM("load "+component+" from "+SVN_REPO+SVN_PATH+" ",
                    "svn co --non-interactive "+revision+" "+SVN_REPO+SVN_PATH+" "+target_dir,
                    from_validation)


import sys
import os
import errno
import operator
import time
import glob
import string
import platform
import smtplib
import datetime
import copy
import multiprocessing
import subprocess
import re

def Main(llvm_base, llvm_version):

    if not os.path.exists(llvm_base):
        error("Can't find llvm build base folder {}".format(llvm_base))

    version_LLVM = llvm_version
    LLVM_SRC_BASE = llvm_base
    LLVM_SRC = "{}/llvm_{}".format(LLVM_SRC_BASE, version_LLVM)


    # llvm build root
    LLVM_BUILD = '{}/llvm-build-{}'.format(LLVM_SRC_BASE, version_LLVM)
    # llvm bin root (install path)
    LLVM_BIN = '{}/llvm-bin-{}'.format(LLVM_SRC_BASE, version_LLVM)

    pwd = os.getcwd();
    use_git = True
    extra = False
    revision = ''
    from_validation = False

    if current_OS == 'Windows':
        generator = 'Visual Studio 15 2017'
    else:
        generator = 'Unix Makefiles'

    print 'Checking out LLVM......'
    if os.path.exists(LLVM_SRC):
        print 'llvm source foler {} exsit! assuming already cloned!'.format(LLVM_SRC)
    else:
        make_sure_dir_exists(LLVM_SRC)
        checkout_LLVM("llvm", use_git, version_LLVM, revision, LLVM_SRC, from_validation)

    tool_path = '{}/tools/'.format(LLVM_SRC)
    clang_tool_path = '{}/tools/clang'.format(LLVM_SRC)
    if os.path.exists(clang_tool_path):
        print 'llvm source foler {} exsit! assuming already cloned!'.format(clang_tool_path)
    else:
        make_sure_dir_exists(tool_path)
        os.chdir(tool_path)
        checkout_LLVM("clang", use_git, version_LLVM, revision, "clang", from_validation)
        os.chdir("..")

    if current_OS == "MacOS" and int(current_OS_version.split(".")[0]) >= 13:
        # Starting with MacOS 10.9 Maverics, the system doesn't contain headers for standard C++ library and
        # the default library is libc++, bit libstdc++. The headers are part of XCode now. But we are checking out
        # headers as part of LLVM source tree, so they will be installed in clang location and clang will be able
        # to find them. Though they may not match to the library installed in the system, but seems that this should
        # not happen.
        # Note, that we can also build a libc++ library, but it must be on system default location or should be passed
        # to the linker explicitly (either through command line or environment variables). So we are not doing it
        # currently to make the build process easier.
        os.chdir("{}/projects".format(LLVM_SRC))
        if(os.path.exists('libcxx')):
                print 'libcxx already exists. Assuming already cloned'
        else:
            checkout_LLVM("libcxx", use_git, version_LLVM, revision, "libcxx", from_validation)
        os.chdir("..")
    if extra == True:
        print os.getcwd()
        clang_tool_path = '{}/clang/tools'.format(LLVM_SRC)
        if os.path.exists(clang_tool_path):
            print 'llvm source foler {} exsit! assuming already cloned!'.format(clang_tool_path)
        else:
            make_sure_dir_exists(clang_tool_path)
            os.chdir(clang_tool_path)
            checkout_LLVM("clang-tools-extra", use_git, version_LLVM, revision, "extra", from_validation)
            os.chdir("../../projects")
            checkout_LLVM("compiler-rt", use_git, version_LLVM, revision, "compiler-rt", from_validation)

            os.chdir("..")

    # now patch for ispc
    print 'Patching llvm for ISPC......'
    os.chdir(LLVM_SRC)
    patches = glob.glob("{}/llvm_patches".format(pwd) + os.sep + "*.*")
    for patch in patches:
        if version_LLVM in os.path.basename(patch):
            if current_OS != "Windows":
                try_do_LLVM("patch LLVM with patch " + patch + " ", "patch -p0 < " + patch, from_validation)
            else:
                try_do_LLVM("patch LLVM with patch " + patch + " ", "patch -p0 -i " + patch, from_validation)
    os.chdir(pwd)

    # configuring llvm, build first part of selfbuild
    make_sure_dir_exists(LLVM_BUILD)
    make_sure_dir_exists(LLVM_BIN)
    selfbuild_compiler = ""
    LLVM_configure_capable = ["3_2", "3_3", "3_4", "3_5", "3_6", "3_7"]

    print_debug("Making selfbuild and use folders " + LLVM_BUILD + " and " +
        LLVM_BIN + ' with generator ' + generator + "\n", from_validation, alloy_build)

    make_sure_dir_exists(LLVM_BUILD)
    make_sure_dir_exists(LLVM_BIN)

    os.chdir(LLVM_BUILD)
    if  version_LLVM not in LLVM_configure_capable:
        print os.getcwd()
        try_do_LLVM("configure release version for selfbuild ",
                "cmake -G " + "\"" + generator + "\"" + " -DCMAKE_EXPORT_COMPILE_COMMANDS=ON" +
                "  -DCMAKE_INSTALL_PREFIX=" + LLVM_BIN +
                "  -DCMAKE_BUILD_TYPE=Release" +
                get_llvm_enable_dump_switch(version_LLVM) + "  -DLLVM_ENABLE_ASSERTIONS=ON" + "  -DLLVM_INSTALL_UTILS=ON" +
                "  -DLLVM_TARGETS_TO_BUILD=NVPTX\;X86\;ARM\;AArch64" +  " " + LLVM_SRC,
                from_validation)
        selfbuild_compiler = ("  -DCMAKE_C_COMPILER=" + LLVM_SRC + "/" + LLVM_BIN + "/bin/clang " +
                                "  -DCMAKE_CXX_COMPILER="+ LLVM_SRC + "/" + LLVM_BIN + "/bin/clang++ ")

        if current_OS != "Windows":
            try_do_LLVM("build release version for selfbuild ",
                        'make -j12', from_validation)
            try_do_LLVM("install release version for selfbuild ",
                        "make install",
                        from_validation)
        else:
            try_do_LLVM("build & install release version for selfbuild",
                    "cmake --build . --config release --target install", from_validation)
    os.chdir("../")

    print_debug("Now we have compiler for selfbuild: " + selfbuild_compiler + "\n", from_validation, alloy_build)

    os.chdir(LLVM_BUILD)

if __name__ == '__main__':
    LLVM_HOME_ENV_NAME = 'LLVM_HOME'
    LLVM_HOME_PATH = os.getenv(LLVM_HOME_ENV_NAME)
    if LLVM_HOME_PATH is None:
        print 'unable to find llvm home from enviroment varialbe {}'.format(LLVM_HOME_ENV_NAME)
    llvm_home = os.environ[LLVM_HOME_ENV_NAME]


    version_LLVM = '5_0'
    LLVM_SRC_BASE = llvm_home
    Main(LLVM_SRC_BASE, version_LLVM)

