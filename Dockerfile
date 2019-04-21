FROM alpine:3.3

# Download the Erlang/OTP source
RUN mkdir /buildroot
WORKDIR /buildroot
ADD https://github.com/erlang/otp/archive/OTP-20.1.7.tar.gz .
RUN tar zxf OTP-20.1.7.tar.gz

# Install additional packages
RUN apk add --no-cache autoconf && \
    apk add --no-cache alpine-sdk && \
    apk add --no-cache openssl-dev

# Build Erlang/OTP
WORKDIR otp-OTP-20.1.7
RUN ./otp_build autoconf && \
    CFLAGS="-Os" ./configure --prefix=/buildroot/erlang/20.1.7 --without-termcap --disable-hipe && \
    make -j10

RUN ls -lh .
# Install Erlang/OTP
RUN mkdir -p /buildroot/erlang/20.1.7 && \
    make install

# Install Rebar3
RUN mkdir -p /buildroot/rebar3/bin
ADD https://s3.amazonaws.com/rebar3/rebar3 /buildroot/rebar3/bin/rebar3
RUN chmod a+x /buildroot/rebar3/bin/rebar3

# Setup Environment
ENV PATH=/buildroot/erlang/20.1.7/bin:/buildroot/rebar3/bin:$PATH

WORKDIR /hubot-cloud-client

RUN ls -lh .

COPY . .

CMD rebar3 release -o server

RUN ls -lh .

EXPOSE 3000

RUN ls -lh /hubot-cloud-client

ENTRYPOINT ["/hubot-cloud-client/server"]
CMD ["foreground"]
