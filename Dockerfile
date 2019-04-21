FROM arm32v7/erlang:21

WORKDIR /hubot-cloud-client
COPY . .

RUN rebar3 as prod tar

RUN mkdir -p /opt/rel
RUN tar -zxvf /hubot-cloud-client/_build/prod/rel/*/*.tar.gz -C /opt/rel

RUN ls -lh /opt/rel

ENTRYPOINT ["/opt/rel/bin/client", "foreground"]
