# INF-2204 Project

We measure how a program's running time and executions are spread over
its instructions, source lines and functions, and study the shape of
that spread across programs and machines.

## Setup

Install the tools. On Ubuntu:

```sh
sudo apt install build-essential curl unzip xz-utils valgrind libc6-dbg python3 python3-matplotlib linux-tools-common linux-tools-$(uname -r)
```

On Debian or Raspberry Pi OS:

```sh
sudo apt install build-essential curl unzip xz-utils valgrind libc6-dbg python3 python3-matplotlib linux-perf
```

Name your machine (letters, digits, _; the same name every time):

```sh
export nick=
```

## Measure

In this folder, with a laptop on its charger:

```sh
sudo scripts/measure -n "$nick" all
```

This builds the programs, downloads their inputs (900 MB) and measures
each workload in `workloads.txt`. Wi-Fi and Bluetooth are off during
the time runs: over ssh on Wi-Fi, run it inside `screen`. If it stops
early, it prints a command that runs the workloads it did not finish.
Results go to `measurements/<workload>/`.

## After a git pull

`make` rebuilds a program whenever the Makefile has changed. For
`build/cc1` and `build/clang` that takes hours on a Raspberry Pi. If
the change did not touch how they are built (it says so in its
description), mark them as up to date instead (`-c`: only those you
have built):

```sh
touch -c build/cc1 build/clang build/git
```

## Cleaner measurements

`tune` prints kernel boot options that keep other work off the
measured CPU, e.g. `tune: for full isolation, also boot with isolcpus=3
rcu_nocbs=3`. Add them, then reboot:

- Ubuntu: inside the quotes of `GRUB_CMDLINE_LINUX_DEFAULT` in
  `/etc/default/grub`, then run `sudo update-grub`.
- Raspberry Pi OS: at the end of the one line in
  `/boot/firmware/cmdline.txt`, after a space; it must stay one line.

## If measure or record refuses to start

If a run was killed outright, the machine may still be tuned:

```sh
sudo scripts/tune reset
```

## Scripts

- `measure`: builds the programs and measures every workload.
- `record`: measures one program.
- `tune`: sets the machine up for measuring, and back.
- `rank`: makes the ranked lists.
- `graphing <list.csv>`: plots a list in a window.

All are in `scripts/`. The first four show their help with `-h`.

---

Parts of this file were written by Claude Code, Anthropic's AI coding
assistant.
