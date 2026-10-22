FROM nimlang/nim:2.2.4-alpine@sha256:47a9afd5e2d02f6a48fa13235462cb7356c4a04f7705689829f15b29d3fd8c4b AS builder

WORKDIR /src

RUN apk add --no-cache openssl-dev pcre-dev git
RUN nimble --nimbleDir:/tmp/nimble install -y https://github.com/zystem/nim-posixglob

COPY bitbucket_rqlite_cache.nimble .
COPY src ./src

RUN nimble --nimbleDir:/tmp/nimble buildRelease -y && \
    mkdir -p /out && \
    cp build/bitbucket-rqlite-cache /out/bitbucket-rqlite-cache


FROM alpine:3.24@sha256:c6b073f8e9e58d881f6ffba6ebf3b9ebd60b9e7d6e8337018c0e68bb5c356873

RUN apk add --no-cache ca-certificates openssl libgcc

COPY --from=builder /out/bitbucket-rqlite-cache /usr/local/bin/bitbucket-rqlite-cache
COPY LICENSE /usr/share/licenses/bitbucket-rqlite-cache/

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/bitbucket-rqlite-cache"]
