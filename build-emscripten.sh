#!/bin/bash

set -e

cd "$(dirname "$0")/nim"

test -x bin/nim || ./bootstrap.sh

# bin/nim compile \
#         --symbolfiles:off \
#         --gen_mapping \
#         --cc:gcc \
#         -d:emscripten \
#         -d:release \
#         --cpu:i386 \
#         --os:linux \
#         --compileonly \
#         --skipUserCfg \
#         ../emscripten_compiler.nim

source_files=$(sed -n 's/.*\/\(.*\.c\).*/..\/nimcache\/\1/p' < ../mapping.txt)

CPATH=../nimcache emcc \
    --preload-file lib/system.nim \
    --preload-file lib/system/inclrtl.nim \
    --preload-file lib/system/jssys.nim \
    --preload-file lib/system/hti.nim \
    --preload-file lib/system/reprjs.nim \
    --preload-file lib/nimrtl.nim \
    --preload-file config/nim.cfg \
    -include ../emscripten.h \
    -Ilib \
    -O3 \
    -s NO_EXIT_RUNTIME=1 \
    -s OUTLINING_LIMIT=40000 \
    -s EXPORTED_FUNCTIONS='["_main", "_fib1", "_fib2"]' \
    -fno-strict-aliasing \
    -w \
    -o ../nim-compiler.js  \
    ${source_files}
