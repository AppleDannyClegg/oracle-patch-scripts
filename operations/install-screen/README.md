# install-screen: GNU screen on a server with no internet

`screen` keeps a long patch run alive when your SSH session drops, and lets you reattach to it. Oracle Linux 9
does not ship it in the base repos (it is in EPEL), so an offline server usually does not have it.

Two steps, the same shape as `patching/patch-manifest.sh` and `patching/get-patches.ps1`:

1. **On a Windows laptop with internet**, download the RPMs. Use the server's major version: `VERSION_ID` in
   `/etc/os-release` (`cat /etc/os-release; uname -m`).

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Get-ScreenRpm.ps1 -EL 9
   scp -r .\screen-el9 oracle@server:/tmp/
   ```

   It fetches `screen` and `libutempter` from yum.oracle.com and checks each file against the checksum the repo
   publishes. `-OutDir` picks the folder (default `.\screen-el<N>`).

2. **On the server**, check, then install:

   ```sh
   bash install-screen.sh --dry-run /tmp/screen-el9
   sudo bash install-screen.sh /tmp/screen-el9
   ```

   It uses only the local files. It stops if `screen` is already there, if the server is not x86_64, or if the
   RPMs are for a different EL version. `libutempter` is installed only when missing.

| EL | screen | libutempter |
|---|---|---|
| 9 | yum.oracle.com `ol9_developer_EPEL` | `ol9_baseos_latest` |
| 7 | `ol7_latest` | `ol7_latest` |
| 8 | not supported: Oracle's EPEL 8 mirror has no screen. Use `tmux` (base repos) | |

Then: `screen -S patch` to start a session, `Ctrl-a d` to detach, `screen -r patch` to reattach.

**Tested:** `Get-ScreenRpm.ps1 -EL 9` and `-EL 7` under PowerShell 7 on macOS (not yet Windows PowerShell 5.1);
`install-screen.sh` in an Oracle Linux 9 x86_64 container with `--network none`, with and without
`libutempter` present, and on a second run. `tests/install-screen.sh` covers its refusals with a fake `rpm`.
Not run on a real server yet.
