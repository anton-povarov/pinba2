#!/bin/bash -xe

# mariadb
cd /_src/mariadb
cmake .

# don't want to build the whole thing, it takes a long time, just what we need
make -C libservices
# boost tries to include this file globally and includes this one; but mariadb needs this to install
mv VERSION VERSION.backup
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
