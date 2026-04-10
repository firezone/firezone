FROM alpine:3.23

RUN apk add --no-cache iproute2 nftables jq bash \
    && apk upgrade --no-cache

HEALTHCHECK --interval=1s --timeout=1s --retries=5 CMD [ "sh", "-c", "test $(cat /tmp/setup_done) = 1" ]

WORKDIR /bin
COPY ./router.sh /bin/router.sh
COPY ./router.nft /bin/router.nft
RUN chmod +x /bin/router.sh

CMD ["router.sh"]
