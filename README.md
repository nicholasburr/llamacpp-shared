# llamacpp-shared

Single source of truth for the files shared across the Fedora + llama.cpp
(ROCm / gfx1151) project repos:

```
Containerfile              ← podman build recipe (builder + runtime stages)
scripts/fedora-setup.sh    ← host setup: GRUB, tuned, podman-compose IPC patch
```

Consuming projects include this repo as a **git submodule + symlinks** —
see `../submodule-poc/README.md` for the full pattern and a working example.

## Consumer-side wiring (per project)

```sh
git submodule add git@github.com:nicholasburr/llamacpp-shared.git llamacpp-shared
ln -s llamacpp-shared/Containerfile Containerfile
mkdir -p scripts
ln -s ../llamacpp-shared/scripts/fedora-setup.sh scripts/fedora-setup.sh
git add .gitmodules llamacpp-shared Containerfile scripts/fedora-setup.sh
git commit -m 'Share Containerfile + fedora-setup.sh via submodule'
```

## Updating a consumer after a change here

```sh
cd <consumer-project>
git submodule update --remote llamacpp-shared   # or: cd llamacpp-shared && git pull
git add llamacpp-shared
git commit -m 'Bump llamacpp-shared: <what changed>'
git push --recurse-submodules=on-demand
```

## Conventions

- `TAG` and `REPO` stay **build args** in the Containerfile — each consumer
  pins its own llama.cpp version (via its `TAGS` file / `BuildArg=TAG=`).
- Keep the two files at these exact paths; consumers symlink to them.
- Bump the pinned commit in consumers deliberately: a consumer build is
  reproducible only because the submodule pin is part of its commit.
