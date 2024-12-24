FROM ubuntu:24.04 AS builder

SHELL [ "/bin/bash", "-c" ]

ARG NANOMSG_VERSION=1.2.1
ARG LZ4_VERSION=1.10.0

COPY <<EOF /etc/apt/sources.list.d/universe_src.sources
Types: deb-src
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble-updates
Components: universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

RUN apt-get update && apt-get install -y \
    apt-src \
    ca-certificates \
    libboost-dev \
    git \
    curl

# USER		ubuntu
WORKDIR		/_src

RUN apt-get build-dep -y mariadb-server
RUN apt-get source -y mariadb-server && \
    MARIADB_VERSION=$(apt-cache showsrc mariadb-server | grep '^Version:' | head -n1 | cut -d':' -f3 | cut -d '-' -f1) && \
    mv mariadb-$MARIADB_VERSION mariadb

# Download code dependencies
RUN git clone --branch master --single-branch --depth 1 https://github.com/anton-povarov/meow /_src/meow

RUN curl -L https://github.com/nanomsg/nanomsg/archive/refs/tags/${NANOMSG_VERSION}.tar.gz | \
    tar xvz -C /tmp && \
    mv -v /tmp/nanomsg-${NANOMSG_VERSION} /_src/nanomsg

RUN curl -L https://github.com/lz4/lz4/archive/refs/tags/v${LZ4_VERSION}.tar.gz | \
    tar xvz -C /tmp && \
    mv -v /tmp/lz4-${LZ4_VERSION} /_src/lz4

COPY . /_src/pinba2
RUN /_src/pinba2/docker/build-dependencies.sh
RUN /_src/pinba2/docker/build-pinba.sh

FROM ubuntu:24.04

# libmariadb-dev-compat - for mysql_config
RUN apt-get update && apt-get install -y \
    file \
    hostname \
    libjemalloc2 \
    libjemalloc-dev \
    libmariadb-dev-compat \
    mariadb-server

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --from=builder /_src/pinba2/mysql_engine/.libs/libpinba_engine2.so /usr/lib/mysql/plugin/

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
# TODO: Add bats based health check for exposed ports
EXPOSE 3002/udp
EXPOSE 3306/tcp
CMD ["mysqld"]
