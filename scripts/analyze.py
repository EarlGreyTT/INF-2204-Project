#!/usr/bin/env python3
"""
Split N profiling runs into two seeded-random groups, average per instruction,
rank the averaged result, and compare the groups.

Usage:
  python analyze.py DIR [--kind function-samples] [--seed 42] [--out results]

DIR holds files like gospi-1.run1.function-samples.csv ... run10.
--kind picks which CSV type to read: function-samples, line-samples or samples.
All columns except rank/count form the key that identifies an "instruction".
"""
import argparse, glob, os, random, sys
import numpy as np
import pandas as pd
from scipy import stats

SKIP = ("rank", "count")


def load(path):
    df = pd.read_csv(path, dtype=str, keep_default_na=False)
    if "source" in df.columns:  # stray address-level block with 0x... offsets
        addr = df["source"].str.match(r"^0x[0-9a-fA-F]+$")
        if addr.any():
            print(f"{os.path.basename(path)}: dropped {addr.sum()} address-level rows", file=sys.stderr)
        df = df[~addr]
    df = df.copy()
    df["count"] = pd.to_numeric(df["count"])
    keys = [c for c in df.columns if c not in SKIP]
    return df.groupby(keys, as_index=False)["count"].sum(), keys


def build_matrix(paths):
    cols, keys = {}, None
    for p in paths:
        d, k = load(p)
        if keys is None:
            keys = k
        elif k != keys:
            sys.exit(f"{p}: columns {k} differ from {keys}")
        cols[os.path.basename(p)] = d.set_index(keys)["count"]
    return pd.DataFrame(cols).fillna(0.0), keys  # absent in a run = 0 samples


def group_table(M, keys):
    n = M.shape[1]
    t = stats.t.ppf(0.975, n - 1) if n > 1 else np.nan
    o = pd.DataFrame(index=M.index)
    o["mean"] = M.mean(axis=1)
    o["median"] = M.median(axis=1)
    o["variance"] = M.var(axis=1, ddof=1)
    o["sd"] = M.std(axis=1, ddof=1)
    o["cv"] = o["sd"] / o["mean"].replace(0, np.nan)
    o["sem"] = o["sd"] / np.sqrt(n)
    o["ci95_lo"] = o["mean"] - t * o["sem"]
    o["ci95_hi"] = o["mean"] + t * o["sem"]
    o["min"] = M.min(axis=1)
    o["max"] = M.max(axis=1)
    o["share"] = o["mean"] / o["mean"].sum()
    o = o.sort_values("mean", ascending=False)
    o["cum_share"] = o["share"].cumsum()
    o.insert(0, "rank", np.arange(1, len(o) + 1))
    o = o.reset_index()
    first = ["rank", "mean"] + keys
    return o[first + [c for c in o.columns if c not in first]]


def loglog_fit(means):
    v = np.sort(np.asarray(means, float))[::-1]
    v = v[v > 0]
    r = np.arange(1, len(v) + 1)
    res = stats.linregress(np.log(r), np.log(v))
    return dict(beta=-res.slope, C=float(np.exp(res.intercept)), r2=res.rvalue ** 2, n=len(v))


def boot_beta(M, reps, rng):
    n = M.shape[1]
    b = [loglog_fit(M.iloc[:, rng.integers(0, n, n)].mean(axis=1))["beta"] for _ in range(reps)]
    return np.percentile(b, [2.5, 97.5])


def powerlaw_extras(means, label, lines):
    try:
        import powerlaw
    except ImportError:
        lines.append(f"[{label}] pip install powerlaw -> adds MLE alpha, xmin, KS D, model comparison")
        return
    v = np.asarray(means, float)
    v = v[v > 0]
    fit = powerlaw.Fit(v, verbose=False)
    lines.append(f"[{label}] MLE alpha={fit.power_law.alpha:.3f} (SE {fit.power_law.sigma:.3f}), "
                 f"xmin={fit.power_law.xmin:.4g}, KS D={fit.power_law.D:.4f}")
    for alt in ("lognormal", "exponential", "stretched_exponential"):
        R, p = fit.distribution_compare("power_law", alt)
        lines.append(f"[{label}] power_law vs {alt}: R={R:.3f}, p={p:.3f} (R>0 favours power law)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir", help="directory containing the run CSVs")
    ap.add_argument("--kind", default="function-samples",
                    help="function-samples | line-samples | samples")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="results")
    ap.add_argument("--boot", type=int, default=1000)
    a = ap.parse_args()

    paths = sorted(glob.glob(os.path.join(a.dir, f"*.{a.kind}.csv")))
    if len(paths) < 4:
        sys.exit(f"Found {len(paths)} files matching *.{a.kind}.csv in {a.dir}")
    random.Random(a.seed).shuffle(paths)
    half = len(paths) // 2
    groups = {"A": paths[:half], "B": paths[half:]}
    os.makedirs(a.out, exist_ok=True)

    M, keys = build_matrix(paths)
    Ms = {g: M[[os.path.basename(p) for p in groups[g]]] for g in "AB"}
    MA, MB = Ms["A"], Ms["B"]

    lines = [f"kind={a.kind} seed={a.seed} runs={len(paths)}"]
    for g in "AB":
        lines.append(f"group {g}: " + ", ".join(os.path.basename(p) for p in groups[g]))

    for g in "AB":
        group_table(Ms[g], keys).to_csv(f"{a.out}/group_{g}_average.csv", index=False)

    rows = []
    for k in M.index:
        x, y = MA.loc[k].values, MB.loc[k].values
        delta = x.mean() - y.mean()
        sp = np.sqrt(((len(x) - 1) * x.var(ddof=1) + (len(y) - 1) * y.var(ddof=1)) / (len(x) + len(y) - 2))
        with np.errstate(all="ignore"):
            t_p = stats.ttest_ind(np.log1p(x), np.log1p(y), equal_var=False).pvalue
        try:
            u_p = stats.mannwhitneyu(x, y, alternative="two-sided").pvalue
        except ValueError:
            u_p = np.nan
        kk = k if isinstance(k, tuple) else (k,)
        rows.append({**dict(zip(keys, kk)), "mean_A": x.mean(), "mean_B": y.mean(), "delta": delta,
                     "cohen_d": delta / sp if sp > 0 else np.nan,
                     "welch_p_log": t_p, "mannwhitney_p": u_p})
    cmp = pd.DataFrame(rows).sort_values("welch_p_log")
    cmp.to_csv(f"{a.out}/between_groups.csv", index=False)

    rho, rho_p = stats.spearmanr(MA.mean(axis=1), MB.mean(axis=1))
    lines.append(f"Spearman rho of mean ranks A vs B = {rho:.4f} (p={rho_p:.3g})")
    lines.append(f"Instructions with Welch p<0.05 (uncorrected): {(cmp.welch_p_log < 0.05).sum()} of {len(cmp)} "
                 f"(~5% expected by chance if both groups come from the same test)")

    rng = np.random.default_rng(a.seed)
    for g in "AB":
        f = loglog_fit(Ms[g].mean(axis=1))
        lo, hi = boot_beta(Ms[g], a.boot, rng)
        lines.append(f"[{g}] log-log OLS: beta={f['beta']:.3f} (95% boot CI {lo:.3f}..{hi:.3f}), "
                     f"C={f['C']:.4g}, R^2={f['r2']:.4f}, n={f['n']}")
        powerlaw_extras(Ms[g].mean(axis=1), g, lines)

    open(f"{a.out}/summary.txt", "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
