# INF-2204 Project

We measure how a program's running time and executions are spread over
its instructions, source lines and functions, and study the shape of
that spread across programs and machines.

## Setup

Install the tools. On Ubuntu:

```sh
sudo apt install build-essential m4 git curl rsync unzip xz-utils valgrind python3-matplotlib python3-scipy cmake ninja-build linux-tools-$(uname -r)
```

On Debian or Raspberry Pi OS:

```sh
sudo apt install build-essential m4 git curl rsync unzip xz-utils valgrind python3-matplotlib python3-scipy cmake ninja-build linux-perf
```

Name your machine (letters, digits, _; the same name every time):

```sh
export nick=
```

## Measure

In this folder, with a laptop on its charger:

```sh
sudo scripts/measure -n "$nick" -r 10 all
```

This builds the programs, downloads their inputs (1.5 GB; `build/`
takes about 12 GB of disk) and measures each workload in
`workloads.txt`. The compile workloads need our own compilers,
`build/cc1` and `build/clang`: the first run builds them, which takes
hours on a Raspberry Pi. On a Raspberry Pi the counts also need our
own valgrind, `build/valgrind`, with a fix for arm64; the first run
builds that too. First come the time runs of every workload,
then one count of each (callgrind, several at a time; on a Raspberry
Pi this part takes the better part of a day). Wi-Fi and Bluetooth are
off during the time runs: over ssh on Wi-Fi, run it inside `screen`.
If it stops early, run the same command again: it measures only what
is left.
Results go to `measurements/<workload>/`.

The four slowest counts (gcc and clang building git and Neovim, hours
each) come last: you can stop `measure` then (Ctrl-C) and keep
everything else. To leave them out from the start:

```sh
sudo scripts/measure -n "$nick" -r 10 -s all
```

## After a git pull

`make` rebuilds a program whenever the Makefile has changed. For
`build/cc1` and `build/clang` that takes hours on a Raspberry Pi. If
the change did not touch how the programs are built (it says so in its
description), mark them all as up to date instead, in one command (`-c`:
only those you have built):

```sh
touch -c build/zlib/lib/libz.a build/zstd build/xz build/speedtest1 build/magick build/git build/cc1 build/clang build/neovim-deps/done build/repo build/compile/sqlite build/compile/*.tar
```

A compile workload can still refuse an old `build/compile/*.tar` ("made
with other settings"), for example after a change to
`scripts/workloads/compile`. It then prints the command that remakes it.

## Cleaner measurements

`tune` prints kernel boot options that keep other work off the
measured CPU, e.g. `tune: for full isolation, also boot with isolcpus=3
rcu_nocbs=3 nohz_full=3` (nohz_full only where the kernel has it). Add them, then reboot:

- Ubuntu: inside the quotes of `GRUB_CMDLINE_LINUX_DEFAULT` in
  `/etc/default/grub`, then run `sudo update-grub`.
- Raspberry Pi OS: at the end of the one line in
  `/boot/firmware/cmdline.txt`, after a space; it must stay one line.

## If measure or record refuses to start

If a run was killed outright, the machine may still be tuned:

```sh
sudo scripts/tune reset
```

## Share

Once, with the ssh destination the server's owner gives you:

```sh
git config share.remote <destination>
```

Then `scripts/share upload` sends your measurements; `scripts/share -h`
shows the rest.

## Scripts

- `measure`: builds the programs and measures every workload.
- `record`: measures one program.
- `tune`: sets the machine up for measuring, and back.
- `rank`: makes the ranked lists.
- `share`: uploads and downloads measurements.
- `stack`: draws many ranked lists in one picture.
- `graphing <list.csv>`: plots a list in a window.
- `average_total_samples`: averages samples per instruction of each run into one .csv file. insignificant. 
- `merge_samples`: loops through a configed directory and averages the samples per instruction for all runs on the same machine, workload, dataset and level of granularity.
- `fit-distributions <list.csv>`: finds which distribution a list's
  counts follow.

All are in `scripts/`. The first six and `fit-distributions` show their
help with `-h`.

---

Parts of this file were written by Claude Code, Anthropic's AI coding
assistant.
