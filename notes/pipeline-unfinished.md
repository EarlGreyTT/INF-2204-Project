nokka sånt i imagine

# compile

```sh
gcc -O2 -g -fno-omit-frame-pointer -falign-functions=32 -falign-loops=32 -o program program.c
```

# record (on linux)

## tune machine so measurements are less noisy

```sh
sudo sh tune-bench.sh
```

## record

*todo: record P mode* 
`ctrl+c` to stop
```sh
sudo perf record -e cycles:P -g -- ./program
```

if tuning crashed or something, you can manually reset:
```sh
sudo sh tune-bench.sh --reset
```

# time-ranked distribution?
```sh
sudo perf script -i perf.data -G -F ip,sym,symoff,dso | awk '{$1 = ""; sub(/\(.*\//, "("); print}' | sort | uniq -c | sort -rn | awk '{print NR, $0}' > instr.txt
```

# visualize
```sh
sudo apt install gnuplot-qt
```

```sh
gnuplot -p -e "set logscale xy; set title 'Samples per instruction, ranked (quicksort, n = 10^8)'; set xlabel 'Rank'; set ylabel 'Samples'; plot 'instr.txt' using 1:2 with points title 'all code'"
```

---

# show assembly
```sh
objdump -d --no-show-raw-insn program
```

or make a file out of it
```sh
objdump -d --no-show-raw-insn program > functions.txt
```

# idk, ignore?
```sh
perf annotate
```
