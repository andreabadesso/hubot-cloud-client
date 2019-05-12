FROM arm32v7/erlang:21 as builder

WORKDIR /hubot-cloud-client

COPY . .

RUN rebar3 as prod tar && \
    mkdir -p /opt/rel && \
    tar -zxvf /hubot-cloud-client/_build/prod/rel/*/*.tar.gz -C /opt/rel && \
    rm -rf /hubot-cloud-client/

FROM arm32v7/erlang:21-slim

COPY --from=builder /opt/rel/ /opt/rel/

ENTRYPOINT ["/opt/rel/bin/client", "foreground"]
