FROM arm32v7/erlang:21 as builder

WORKDIR /hubot-cloud-client
COPY . .

RUN rebar3 as prod tar

RUN mkdir -p /opt/rel
RUN tar -zxvf /hubot-cloud-client/_build/prod/rel/*/*.tar.gz -C /opt/rel

FROM ubuntu:16.04

WORKDIR /opt/

COPY --from=builder /opt/rel /opt/

ENTRYPOINT ["/opt/rel/bin/client", "foreground"]
