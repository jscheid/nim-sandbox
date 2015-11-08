#!/bin/sh
set -e
set -x

if [ ! -e csources/.git ]; then
	git clone --depth 1 git://github.com/nim-lang/csources.git csources
fi

cd "csources"
sh build.sh
cd ".."

./bin/nim c koch
./koch boot -d:release
./koch geninstall

set +x

echo
echo 'Install Nim using "./install.sh <dir>" or "sudo ./install.sh <dir>".'

exit 0
