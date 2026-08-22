# Upstream synchronization

The Blazn fork preserves the upstream repository as a read-only remote:

```text
origin    https://github.com/blazncloud/blazn-computer-use.git
upstream  https://github.com/minghinmatthewlam/computer-use-mcp.git
```

Configure and verify a clean clone:

```bash
scripts/upstream_sync.sh --configure --fetch --check
```

The script refuses dirty work, never pushes, does not rewrite history, and
exits `3` when the fork is behind upstream. When that happens:

1. create a dedicated `blazn/upstream-sync-YYYYMMDD` branch from `origin/main`;
2. merge or rebase the exact `upstream/main` commit under review;
3. run unit, build, protocol, qualification, package, and required live gates;
4. open and review a fork-local PR;
5. merge only after the exact candidate commit is green.

Never force-push `main` or mix an upstream synchronization with feature work.
