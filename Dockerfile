FROM nimlang/nim:2.2.4-alpine AS builder

WORKDIR /src

RUN apk add --no-cache openssl-dev pcre-dev git
RUN nimble --nimbleDir:/tmp/nimble install -y https://github.com/zystem/nim-posixglob

COPY bitbucket_rqlite_cache.nimble .
COPY bitbucket_rqlite_cache.nim .
COPY build.sh .

RUN NIMBLE_DIR=/tmp/nimble ./build.sh && \
    mkdir -p /out && \
    cp build/bitbucket-rqlite-cache /out/bitbucket-rqlite-cache


FROM alpine:3.24

RUN apk add --no-cache ca-certificates openssl libgcc

COPY --from=builder /out/bitbucket-rqlite-cache /usr/local/bin/bitbucket-rqlite-cache

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/bitbucket-rqlite-cache"]
