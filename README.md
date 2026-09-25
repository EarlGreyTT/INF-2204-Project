# INF-2204 Project

Group project for INF-2204 at UiT. We rank a program's instructions by
their share of its execution time and of its executed instructions, and
study the shape of that ranked distribution across programs and
platforms.

## Layout

```
reports/       reports, one PDF per assignment
figures/       figures used in the reports
src/           test programs to measure (third-party ones: Makefile)
Makefile       builds the measured programs
scripts/       measurement pipeline
measurements/  recorded data, created by scripts/record (not committed)
```

## Requirements

Linux with systemd, and `perf`, `valgrind`, `binutils`, `python3`,
`gcc`, `make`, `curl`. Recording needs root, and a laptop must be on
its charger.

## Usage

```sh
make
sudo scripts/record all -n <nick> -r 3 ./build/quicksort 10000000
```

`<nick>` is a nickname for the system you measure on, e.g. `t14`. Each
script explains itself with `-h`.

| Script | What it does |
|---|---|
| `tune` | Isolates one CPU for measuring, and restores the system afterwards. |
| `record` | Records a program's time (perf) and instruction counts (callgrind). |
| `rank` | Ranks a recording's instructions, or shows one function's. |

If a tuned system is ever left tuned, run `sudo scripts/tune reset`.
