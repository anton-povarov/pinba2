#!/bin/bash -xe

# Run this after build-dependencies.sh
# pinba
cd /_src/pinba2
./buildconf.sh
./configure --prefix=/_install/pinba2 \
	--with-boost=/usr \
	--with-mysql=/_src/mariadb \
	--with-meow=/_src/meow \
	--with-nanomsg=/_install/nanomsg \
	--with-lz4=/_install/lz4 \
	--enable-libmysqlservices
make -j4
