FROM alpine:3.16

MAINTAINER "Marco Cirillo" <marco.cirillo@aria-net.org>

# Install dependencies and add daemon user

RUN apk add --upgrade --no-cache busybox-extras build-base linux-headers make git lua5.3 lua5.3-dev lua5.3-socket lua5.3-expat \
	lua5.3-filesystem lua5.3-dbi-mysql lua5.3-dbi-postgresql lua5.3-dbi-sqlite3 lua5.3-sec libidn libidn-dev \
	openssl openssl-dev libevent libevent-dev zlib zlib-dev luarocks5.3
RUN adduser -S -h /var/lib/metronome metronome && addgroup -S metronome


# Pull from git repo and start building the image

RUN cd /home \
	&& git clone https://github.com/maranda/metronome \
	&& luarocks-5.3 install luaevent \
	&& luarocks-5.3 install lua-zlib

ADD config.unix /home/metronome/

RUN cd /home/metronome && make && make install
RUN mkdir /var/log/metronome /var/run/metronome && chown metronome:metronome /var/log/metronome && chown metronome:metronome /var/run/metronome

# Cleanup

RUN apk del --purge build-base linux-headers make git lua5.3-dev libidn-dev openssl-dev libevent-dev zlib-dev

# Set ports of the container which can be exposed
EXPOSE 80 443 5000 5222 5223 5269 5270 5280 5281 5347 5582

# Set possible volume (directories which can be mounted from the docker host machine)
# like etc/, conf/, certs/, logs/, data/
VOLUME ["/etc/metronome", "/usr/lib/metronome", "/var/lib/metronome", "/var/log/metronome", "/var/run/metronome"]

ADD scripts/start.sh /start.sh
RUN chmod 755 /start.sh
USER metronome:metronome

# Define script which should be executed on container startup
CMD ["/bin/sh", "/start.sh"]
