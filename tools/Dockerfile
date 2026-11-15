# Tiny toolbox: dig/curl/jq for the verification Jobs (they run in the mgmt cluster) and
# for watch.sh (it runs on the docker network, because the docker-network IPs that k8gb
# returns are not routable from a Mac).
FROM alpine:3
RUN apk add --no-cache bind-tools curl jq bash coreutils
COPY probe.sh /usr/local/bin/probe.sh
RUN chmod +x /usr/local/bin/probe.sh
