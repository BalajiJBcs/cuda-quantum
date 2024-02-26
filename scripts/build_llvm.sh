#!/bin/bash

# ============================================================================ #
# Copyright (c) 2022 - 2024 NVIDIA Corporation & Affiliates.                   #
# All rights reserved.                                                         #
#                                                                              #
# This source code and the accompanying materials are made available under     #
# the terms of the Apache License 2.0 which accompanies this distribution.     #
# ============================================================================ #

# This scripts builds the clang and mlir project from the source in the LLVM submodule.
# The binaries will be installed in the folder defined by the LLVM_INSTALL_PREFIX environment
# variable, or in $HOME/.llvm if LLVM_INSTALL_PREFIX is not defined.
# If Python bindings are generated, pybind11 will be built and installed in the location 
# defined by PYBIND11_INSTALL_PREFIX unless that folder already exists.
#
# Usage:
# bash scripts/build_llvm.sh
# -or-
# bash scripts/build_llvm.sh -c DEBUG
# -or-
# LLVM_INSTALL_PREFIX=/installation/path/ bash scripts/build_llvm.sh
#
# For documentation on how to assemble a complete toolchain, multi-stage builds,
# and OpenMP support within Clang, see
# - https://clang.llvm.org/docs/Toolchain.html
# - https://llvm.org/docs/AdvancedBuilds.html
# - https://github.com/llvm/llvm-project/blob/main/openmp/docs/SupportAndFAQ.rst#q-how-to-build-an-openmp-gpu-offload-capable-compiler

LLVM_INSTALL_PREFIX=${LLVM_INSTALL_PREFIX:-$HOME/.llvm}
LLVM_PROJECTS=${LLVM_PROJECTS:-'clang;lld;compiler-rt;mlir;python-bindings'}
PYBIND11_INSTALL_PREFIX=${PYBIND11_INSTALL_PREFIX:-/usr/local/pybind11}
Python3_EXECUTABLE=${Python3_EXECUTABLE:-python3}

# Process command line arguments
(return 0 2>/dev/null) && is_sourced=true || is_sourced=false
build_configuration=Release
verbose=false

__optind__=$OPTIND
OPTIND=1
while getopts ":c:s:v" opt; do
  case $opt in
    c) build_configuration="$OPTARG"
    ;;
    s) llvm_source="$OPTARG"
    ;;
    v) verbose=true
    ;;
    :) echo "Option -$OPTARG requires an argument."
    if $is_sourced; then return 1; else exit 1; fi
    ;;
    \?) echo "Invalid command line option -$OPTARG" >&2
    if $is_sourced; then return 1; else exit 1; fi
    ;;
  esac
done
OPTIND=$__optind__

working_dir=`pwd`
this_file_dir=`dirname "$(readlink -f "${BASH_SOURCE[0]}")"`
echo "Configured C compiler: $CC"
echo "Configured C++ compiler: $CXX"

# Check if we build python bindings and build pybind11 from source if necessary
projects=(`echo $LLVM_PROJECTS | tr ';' ' '`)
llvm_projects=`printf "%s;" "${projects[@]}"`
if [ -z "${llvm_projects##*python-bindings;*}" ]; then
  mlir_python_bindings=ON
  projects=("${projects[@]/python-bindings}")

  if [ ! -d "$PYBIND11_INSTALL_PREFIX" ] || [ -z "$(ls -A "$PYBIND11_INSTALL_PREFIX"/* 2> /dev/null)" ]; then
    cd "$this_file_dir" && cd $(git rev-parse --show-toplevel)
    echo "Building PyBind11..."
    git submodule update --init --recursive --recommend-shallow --single-branch tpls/pybind11 
    mkdir "tpls/pybind11/build" && cd "tpls/pybind11/build"
    cmake -G Ninja ../ -DCMAKE_INSTALL_PREFIX="$PYBIND11_INSTALL_PREFIX"
    cmake --build . --target install --config Release
  fi
fi

# Prepare the source and build directory
if [ "$llvm_source" = "" ]; then
  echo "Cloning LLVM submodule..."
  cd "$this_file_dir" && cd $(git rev-parse --show-toplevel)
  llvm_source=~/.llvm-project
  llvm_repo="$(git config --file=.gitmodules submodule.tpls/llvm.url)"
  llvm_commit="$(git submodule | grep tpls/llvm | cut -c2- | cut -d ' ' -f1)"
  git clone --filter=tree:0 "$llvm_repo" "$llvm_source"
  cd "$llvm_source" && git checkout $llvm_commit
fi

mkdir -p "$LLVM_INSTALL_PREFIX"
mkdir -p "$llvm_source/build" && cd "$llvm_source/build"
mkdir -p logs && rm -rf logs/* 

# Specify which components we need to keep the size of the LLVM build down.
# To get a list of install targets, check the output of the following command in the build folder:
#   ninja -t targets | grep -Po 'install-\K.*(?=-stripped:)'
echo "Preparing LLVM build..."
llvm_projects=`printf "%s;" "${projects[@]}"`
if [ -z "${llvm_projects##*clang;*}" ]; then
  echo "- including Clang components"
  llvm_components+="clang;clang-format;clang-cmake-exports;clang-headers;clang-libraries;clang-resource-headers;"
  projects=("${projects[@]/clang}")
fi
if [ -z "${llvm_projects##*flang;*}" ]; then
  echo "- including Flang components"
  llvm_components+="flang-new;"
  projects=("${projects[@]/flang}")
fi
if [ -z "${llvm_projects##*mlir;*}" ]; then
  echo "- including MLIR components"
  llvm_components+="mlir-cmake-exports;mlir-headers;mlir-libraries;mlir-tblgen;"
  projects=("${projects[@]/mlir}")
  if [ "$mlir_python_bindings" == "ON" ]; then
    echo "- including MLIR Python bindings"
    llvm_components+="MLIRPythonModules;mlir-python-sources;"
  fi
fi
if [ -z "${llvm_projects##*lld;*}" ]; then
  echo "- including LLD components"
  llvm_enable_zlib=ON # certain system libraries are compressed with ELFCOMPRESS_ZLIB, requiring zlib support for lld
  llvm_components+="lld;"
  projects=("${projects[@]/lld}")
fi
if [ -z "${llvm_projects##*compiler-rt;*}" ]; then
  echo "- including runtime components"
  llvm_runtimes="libcxx;libcxxabi;libunwind;openmp"
  llvm_components+="compiler-rt;compiler-rt-headers;"
  projects=("${projects[@]/compiler-rt}")
fi
echo "- including general tools and components"
llvm_components+="cmake-exports;llvm-headers;llvm-libraries;"
llvm_components+="llvm-config;llvm-ar;llvm-as;llvm-nm;llvm-symbolizer;llc;FileCheck;count;not;"

if [ "$(echo ${projects[*]} | xargs)" != "" ]; then
  echo "- including additional project(s) "$(echo "${projects[*]}" | xargs | tr ' ' ',')
  unset llvm_components
  install_target=install
else 
  install_target=install-distribution-stripped
  if [ -n "$mlir_python_bindings" ]; then
    # Cherry-pick the necessary commit to have a distribution target
    # for the mlir-python-sources; to be removed after we update to LLVM 17.
    echo "Cherry-picking commit 9494bd84df3c5b496fc087285af9ff40d7859b6a"
    git cherry-pick --no-commit 9494bd84df3c5b496fc087285af9ff40d7859b6a
    if [ ! 0 -eq $? ]; then
      echo "Cherry-pick failed."
      if $(git rev-parse --is-shallow-repository); then
        echo "Unshallow the repository and try again."
        if $is_sourced; then return 1; else exit 1; fi
      fi
    fi
  fi
fi

# A hack, since otherwise the build can fail due to line endings in the LLVM script:
cat "../llvm/cmake/config.guess" | tr -d '\r' > ~config.guess
cat ~config.guess > "../llvm/cmake/config.guess" && rm -rf ~config.guess

# Generate CMake files; -DCLANG_RESOURCE_DIR=...
#  -DLIBCXXABI_ENABLE_SHARED=OFF \
#  -DLIBUNWIND_ENABLE_SHARED=OFF \
#  -DLIBCXX_ENABLE_SHARED=OFF \
#  -DBOOTSTRAP_LLVM_ENABLE_LLD=TRUE \
#  -DLIBCXX_STATICALLY_LINK_ABI_IN_STATIC_LIBRARY=ON 
#  -DLIBCXXABI_STATICALLY_LINK_UNWINDER_IN_STATIC_LIBRARY=ON
#  -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY - see https://libcxx.llvm.org/BuildingLibcxx.html
#  -DLIBCXX_HERMETIC_STATIC_LIBRARY - see https://libcxx.llvm.org/BuildingLibcxx.html
# see also https://github.com/llvm/llvm-project/issues/62114
# variables set manually: 
# - LD_LIBRARY_PATH to find the built libc++ binaries
# - LIBRARY_PATH to find the built libc++ binaries
# - CUDAHOSTCXX="$CXX", since otherwise CUDA check was unhappy
cmake_args="-G Ninja ../llvm \
  -DLLVM_TARGETS_TO_BUILD="host" \
  -DCMAKE_BUILD_TYPE=$build_configuration \
  -DCMAKE_INSTALL_PREFIX="$LLVM_INSTALL_PREFIX" \
  -DCLANG_RESOURCE_DIR='..' \
  -DLLVM_ENABLE_PROJECTS="$llvm_projects" \
  -DLLVM_ENABLE_RUNTIMES="$llvm_runtimes" \
  -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
  -DLLVM_DISTRIBUTION_COMPONENTS="$llvm_components" \
  -DLLVM_ENABLE_LIBCXX=ON \
  -DLIBCXX_CXX_ABI=libcxxabi \
  -DLIBCXX_USE_COMPILER_RT=ON \
  -DLIBCXXABI_USE_COMPILER_RT=ON \
  -DLIBUNWIND_USE_COMPILER_RT=ON \
  -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
  -DCOMPILER_RT_USE_LIBCXX=ON \
  -DLIBCXX_HAS_GCC_LIB=FALSE \
  -DLIBCXX_HAS_GCC_S_LIB=FALSE \
  -DLIBCXX_HAS_ATOMIC_LIB=FALSE \
  -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
  -DCLANG_DEFAULT_RTLIB=compiler-rt \
  -DCLANG_DEFAULT_UNWINDLIB=libunwind \
  -DCLANG_DEFAULT_OPENMP_RUNTIME=libomp \
  -DCLANG_DEFAULT_LINKER=lld \
  -DLLVM_ENABLE_BINDINGS=OFF \
  -DMLIR_ENABLE_BINDINGS_PYTHON=$mlir_python_bindings \
  -DPython3_EXECUTABLE="$Python3_EXECUTABLE" \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_OPTIMIZED_TABLEGEN=ON \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DLLVM_BUILD_EXAMPLES=OFF \
  -DLLVM_BUILD_TESTS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_OCAMLDOC=OFF \
  -DLLVM_ENABLE_ZLIB=${llvm_enable_zlib:-OFF} \
  -DZLIB_ROOT=${ZLIB_INSTALL_PREFIX} \
  -DZLIB_USE_STATIC_LIBS=TRUE \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_INSTALL_UTILS=ON \
  -DCMAKE_CXX_FLAGS='-w'"
if $verbose; then
  cmake $cmake_args
else
  cmake $cmake_args 2> logs/cmake_error.txt 1> logs/cmake_output.txt
fi

# Build and install clang in a folder
echo "Building LLVM with configuration $build_configuration..."
if $verbose; then
  ninja $install_target
  status=$?
else
  echo "The progress of the build is being logged to `pwd`/logs/ninja_output.txt."
  ninja $install_target 2> logs/ninja_error.txt 1> logs/ninja_output.txt
  status=$?
fi

if [ "$status" = "" ] || [ ! "$status" -eq "0" ]; then
  echo "Build failed. Please check the files in the `pwd`/logs directory."
  cd "$working_dir" && if $is_sourced; then return 1; else exit 1; fi
else
  cp bin/llvm-lit "$LLVM_INSTALL_PREFIX/bin/"
  cd "$working_dir" && echo "Installed llvm build in directory: $LLVM_INSTALL_PREFIX"
fi

if [ -n "$llvm_runtimes" ]; then
  cd $llvm_source/build && ninja runtimes && ninja install-runtimes
  status=$?
  if [ "$status" = "" ] || [ ! "$status" -eq "0" ]; then
    echo "Build failed. Please check the files in the `pwd`/logs directory."
    cd "$working_dir" && if $is_sourced; then return 1; else exit 1; fi
  else
    cd "$working_dir" && echo "Successfully added runtime components."
  fi
fi
