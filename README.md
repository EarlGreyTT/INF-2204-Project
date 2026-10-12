# INF-2204 Project

Group project for INF-2204 at UiT. We rank a program's instructions by
their share of its execution time and of its executed instructions, and
study the shape of that ranked distribution across programs and
platforms.

## Layout

```
reports/       reports, one PDF per assignment
figures/       figures used in the reports
src/           our own test programs (the Makefile downloads the others)
Makefile       builds the measured programs
scripts/       measurement pipeline
measurements/  recorded data, created by scripts/record (not committed)
```

## Requirements

Linux with systemd, and `perf`, `valgrind`, `binutils`, `util-linux`,
`python3`, `gcc`, `make`, `curl`, `unzip`. Recording needs root, and a
laptop must be on its charger.

## Usage

```sh
make
make data
sudo scripts/record all -n <nick> -r 3 build/quicksort 10000000
```

`make` builds the programs we measure, from pinned releases (about 10
minutes, 2 with `make -j8`; `make zstd` builds one). `make data`
fetches the files they are run on. `<nick>` is a nickname for the system
you measure on, e.g. `t14`. Each script explains itself with `-h`.

Every program is recorded with `sudo scripts/record all -n <nick>`,
followed by its line from this table, in the repo's folder:

| Program | Goes after `sudo scripts/record all -n <nick>` | What runs |
|---|---|---|
| quicksort (`src/`) | `build/quicksort 10000000` | sorting ten million numbers |
| zstd 1.5.7 | `-q build/zstd -3 -c build/silesia` | compressing the Silesia files, level 3 |
| xz 5.8.4 | `-q build/xz -1 -c build/silesia` | compressing them, level 1 |
| SQLite 3.54.0 | `build/speedtest1 --testset main --singlethread --size 100 :memory:` | SQLite's own benchmark, in memory |
| Git 2.56.0 | `-q build/git -C build/repo log -p` | printing a repository's history with every change |

A `-q` before the program is `record`'s: it throws away what the program
prints, for programs that print their result. While a time run is on,
the radios (Wi-Fi, Bluetooth) are off; over ssh on Wi-Fi the session
freezes meanwhile, so start it inside `screen` or `tmux` there.

| Script | What it does |
|---|---|
| `tune` | Isolates one CPU for measuring, and restores the system afterwards. |
| `record` | Records a program's time (perf) and instruction counts (callgrind). |
| `rank` | Ranks a recording's instructions, or shows one function's. |

If a tuned system is ever left tuned, run `sudo scripts/tune reset`.

### Graphing
Takes in a path to a csv file with the format

| rank | count | function | offset | file |
|---|---|---|---|---|

Make the file executable
```sh
chmod +x graphing
```

Run the script
```sh
./graphing <path> <title (optional)>
```

---

Parts of this file were written by Claude Code, Anthropic's AI coding
assistant.
