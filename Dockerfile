FROM nimlang/nim:2.2.4-alpine AS build

WORKDIR /src

RUN apk add --no-cache openssl-dev pcre-dev

COPY bitbucket_rqlite_cache.nim .

RUN nim c \
    -d:release \
    -d:ssl \
    --mm:orc \
    --threads:on \
    -o:/out/bitbucket_rqlite_cache \
    bitbucket_rqlite_cache.nim


FROM alpine:3.20

RUN apk add --no-cache ca-certificates openssl libgcc

COPY --from=build /out/bitbucket_rqlite_cache /usr/local/bin/bitbucket_rqlite_cache

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/bitbucket_rqlite_cache"]
CMD ["--help"]