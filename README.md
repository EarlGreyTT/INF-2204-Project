# INF-2204 Project

We measure how a program's running time and executions are spread over
its instructions, source lines and functions, and study the shape of
that spread across programs and machines.

## Setup

Install the tools. On Ubuntu:

```sh
sudo apt install build-essential curl unzip valgrind python3 python3-matplotlib linux-tools-common linux-tools-$(uname -r)
```

On Debian or Raspberry Pi OS:

```sh
sudo apt install build-essential curl unzip valgrind python3 python3-matplotlib linux-perf
```

Then, in this folder:

```sh
make -j8      # build the programs (a few minutes)
make data     # download their input files (212 MB)
nick=         # write a short name for your machine after the = (letters, digits, _)
```

## Measure

In this folder, with a laptop on its charger:

```sh
# quicksort (ours): sorts 10 million numbers
sudo scripts/record all -n "$nick" build/quicksort 10000000
# zstd: compresses a standard set of test files
sudo scripts/record all -n "$nick" -q build/zstd -3 -c build/silesia
# xz: compresses the same files
sudo scripts/record all -n "$nick" -q build/xz -1 -c build/silesia
# SQLite: its own speed test, on a database in memory
sudo scripts/record all -n "$nick" build/speedtest1 --testset main --singlethread --size 100 :memory:
# git: prints a small repository's history, with every change
sudo scripts/record all -n "$nick" -q build/git -C build/repo log -p
```

`-q` throws away what the program prints. Wi-Fi and Bluetooth are off
while the time is measured: over ssh on Wi-Fi, start these inside
`screen` or `tmux`.

Each run prints where its files went: `measurements/<program>/time/`
and `count/` (SQLite's are under `speedtest1`). There is one CSV list
each for instructions, lines and functions, most first.

## If a run is cut off

On Ctrl-C or an error, `record` puts the machine back by itself. If it
was killed outright, the next `record` refuses to start. Then run:

```sh
sudo scripts/tune reset
```

## Scripts

- `scripts/record` measures a program. It runs the other two for you.
- `scripts/tune` sets the machine up for measuring, and back.
- `scripts/rank` makes the ranked lists.
- `scripts/graphing <list.csv> [title=<title>]` plots a list in a window.

`scripts/record -h` shows its help; so do `rank` and `tune`.

---

Parts of this file were written by Claude Code, Anthropic's AI coding
assistant.
