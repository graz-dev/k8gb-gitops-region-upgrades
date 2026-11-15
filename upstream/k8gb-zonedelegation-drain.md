# k8gb: draining a cluster's nameserver role (design sketch)

*Draft. Not filed. Smaller than the plugin change, bigger to implement.*

## Problem

Every k8gb cluster plays two roles: it hosts apps, and its CoreDNS is an **authoritative
nameserver** for the load-balanced zone (the parent zone delegates `cloud.example.com` to every
cluster through `gslb-ns-<geo>-<zone>` NS records). Draining a region for maintenance (weights,
failover) covers the first role only. Resolvers keep asking the drained region's nameserver, so
while k8gb itself is changed there, that nameserver is still in use.

Measured (NOTES.md section 5): with eu drained and us healthy, a k8gb in eu that answers wrongly
(NXDOMAIN) made the edge BIND return NXDOMAIN for **100%** of the queries for over a minute;
real clients failed. BIND sticks to the nameserver it prefers and does not fail over on a
negative answer. If eu's CoreDNS is simply *down*, BIND times out and moves to us: much better.

## What exists today

`ZoneDelegation.spec` is `{dnsZoneNegTTL, doFinalize, loadBalancedZone, parentZone}`. The NS set
published by `controllers/providers/k8gbendpoint/delegationDNSEndpoint.go` comes from
`GetActiveNSServerList()`, built from `status.dnsServers` (servers whose glue was discovered).
There is no maintenance switch, and `docs/partial-deployment.md` says deleting the `Gslb` is not
a safe way to exclude a cluster.

## Sketch

A field such as `ZoneDelegation.spec.drained: true` (or an annotation) that makes the local
cluster stop publishing itself in the NS set and the glue records, declared in Git like any other
setting. Cost to document: the NS TTL (`nsRecordTTL`, 30 s) plus resolver caching, so the order is
*DNS-layer drain, wait at least the NS TTL, then change k8gb*. Not implemented here: it needs the
operator and a delegation-aware test.
