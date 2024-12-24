#!/bin/bash -xe

# mariadb
# the annoying part - why we're building mariadb from source at all, 
#  is that we need internal headers that are not present in regular apt packages
#  so the idea here is to avoid building the whole of mariadb, but only the parts we need
#  we only need to run initial generation stage with cmake . and build a few libs quickly
# the final tricky part is to build with the same compiler flags as the server itself
#  for now - there is no problem, unless mariadb is built with debug, in which case pinba should be configured with --enable-debug
cd /_src/mariadb
cmake .
make -C libservices
# boost tries to include this file globally and includes this one; but mariadb needs this to install
# mv+rm is a workaround for docker build-ing on macos case-insensitive fs
#  VERSION and version are the same file and mv actually leads to both files existing at the same time
#  so rm it to avoid the issue with boost described above
mv VERSION VERSION.backup
rm -f VERSION
# make mysqld_error.h available in non-esoteric location
ln -snf /_src/mariadb/libmariadb/include/mysqld_error.h include/mysqld_error.h


# build nanomsg and install (this one is a lil tricky to build statically)
cd /_src/nanomsg
cmake \
	-DNN_STATIC_LIB=ON \
	-DNN_ENABLE_DOC=OFF \
	-DNN_MAX_SOCKETS=4096 \
	-DCMAKE_C_FLAGS="-fPIC -DPIC" \
	-DCMAKE_INSTALL_PREFIX=/_install/nanomsg \
	-DCMAKE_INSTALL_LIBDIR=lib \
	.

make -j4
make install

# build lz4 with PIC static lib
cd /_src/lz4
make CFLAGS="-fPIC -DPIC"
make install PREFIX=/_install/lz4
