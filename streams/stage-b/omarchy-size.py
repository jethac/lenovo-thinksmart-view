#!/usr/bin/env python3
"""Size an Omarchy package set against pacman sync databases, offline.

Resolves the dependency closure the way pacman would pick providers (first
repository in the given order that has the name, else the first provider in
repository order), subtracts what is already installed on the device, and
prints installed and download sizes, the largest packages, and for each
top-level package the size that leaving it out would save.

Usage:
  omarchy-size.py --repo NAME=DB ... --installed PACMAN_Q.txt \
      --targets FILE [--drop FILE] [--explain PKG ...] [--top N]
FILE: one package per line, '#' comments allowed.
"""
import argparse
import re
import sys
import tarfile


def load_db(path, repo):
    pkgs = {}
    with tarfile.open(path) as tf:
        for m in tf.getmembers():
            if not m.name.endswith("/desc"):
                continue
            text = tf.extractfile(m).read().decode()
            fields, key = {}, None
            for line in text.splitlines():
                if line.startswith("%") and line.endswith("%"):
                    key = line.strip("%")
                    fields[key] = []
                elif line and key:
                    fields[key].append(line)
            if "NAME" not in fields:       # the ALARM mirror ships one zero-filled entry
                continue
            p = {
                "name": fields["NAME"][0],
                "version": fields["VERSION"][0],
                "isize": int(fields.get("ISIZE", ["0"])[0]),
                "csize": int(fields.get("CSIZE", ["0"])[0]),
                "depends": [strip(d) for d in fields.get("DEPENDS", [])],
                "provides": [strip(d) for d in fields.get("PROVIDES", [])],
                "repo": repo,
            }
            pkgs[p["name"]] = p
    return pkgs


def strip(dep):
    return re.split(r"[<>=]", dep, 1)[0].strip()


def read_list(path):
    out = []
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(line.split()[0])
    return out


class Resolver:
    def __init__(self, repos, installed):
        self.repos = repos                  # list of (name, {pkg: desc}) in order
        self.installed = installed          # set of names
        self.providers = {}
        for _, pkgs in repos:
            for p in pkgs.values():
                for prov in p["provides"]:
                    self.providers.setdefault(prov, []).append(p)

    def find(self, name, chosen):
        for _, pkgs in self.repos:
            if name in pkgs:
                return pkgs[name]
        cands = self.providers.get(name, [])
        for c in cands:                      # prefer something already picked/installed
            if c["name"] in chosen or c["name"] in self.installed:
                return c
        return cands[0] if cands else None

    def closure(self, targets):
        chosen, missing, stack = {}, set(), list(targets)
        provided = set()
        while stack:
            n = stack.pop()
            if n in chosen or n in provided:
                continue
            p = self.find(n, chosen)
            if p is None:
                missing.add(n)
                continue
            if p["name"] in chosen:
                provided.add(n)
                continue
            chosen[p["name"]] = p
            provided.update(p["provides"])
            stack.extend(p["depends"])
        return chosen, missing


def mib(b):
    return f"{b / 2**20:8.1f} MiB"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", action="append", required=True)
    ap.add_argument("--installed", required=True)
    ap.add_argument("--targets", required=True)
    ap.add_argument("--drop")
    ap.add_argument("--marginal", action="store_true")
    ap.add_argument("--top", type=int, default=30)
    a = ap.parse_args()

    repos = []
    for spec in a.repo:
        name, path = spec.split("=", 1)
        repos.append((name, load_db(path, name)))
    installed = {l.split()[0] for l in open(a.installed) if l.strip()}
    r = Resolver(repos, installed)

    targets = read_list(a.targets)
    if a.drop:
        drop = set(read_list(a.drop))
        targets = [t for t in targets if t not in drop]
    chosen, missing = r.closure(targets)
    new = {n: p for n, p in chosen.items() if n not in installed}
    isz = sum(p["isize"] for p in new.values())
    csz = sum(p["csize"] for p in new.values())
    print(f"targets {len(targets)}, closure {len(chosen)} packages, "
          f"{len(new)} not yet installed")
    print(f"installed size of new packages: {mib(isz)}   download: {mib(csz)}")
    if missing:
        print(f"not resolvable ({len(missing)}): {' '.join(sorted(missing))}")
    byrepo = {}
    for p in new.values():
        byrepo.setdefault(p["repo"], [0, 0])
        byrepo[p["repo"]][0] += 1
        byrepo[p["repo"]][1] += p["isize"]
    print("by repository: " + ", ".join(f"{k} {v[0]} ({v[1] / 2**20:.0f} MiB)" for k, v in byrepo.items()))
    print(f"\nlargest {a.top} new packages:")
    for p in sorted(new.values(), key=lambda p: -p["isize"])[: a.top]:
        print(f"  {mib(p['isize'])}  {p['name']} ({p['repo']})")
    if a.marginal:
        print("\nsaving from leaving out each target (its exclusive dependencies included):")
        rows = []
        for t in targets:
            c2, _ = r.closure([x for x in targets if x != t])
            save = sum(p["isize"] for n, p in new.items() if n not in c2)
            if save > 4 * 2**20:
                rows.append((save, t))
        for save, t in sorted(rows, reverse=True):
            print(f"  {mib(save)}  {t}")


if __name__ == "__main__":
    main()
