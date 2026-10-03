# onix-ops-scripts

Personal stash of one-off ops/restore scripts — not tied to any single
please-payment/please-protect/please-scan repo's normal CI/CD, just a place
to keep scripts that get run by hand on a server somewhere, in case they're
needed again later.

## Scripts

- [`onix-legacy-restore/restore-legacy.rb`](onix-legacy-restore/restore-legacy.rb) — restores a Postgres dump
  into a given postgres pod and a storage/images zip into a given app pod,
  via `kubectl cp`/`kubectl exec`. Written for the x073 work order item 4
  (restoring Onix Legacy data on a standalone VM, no container/cronjob).
