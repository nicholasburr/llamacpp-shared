# llamacpp-shared

Single source of truth for the files shared across the Fedora + llama.cpp
(ROCm / gfx1151) project repos:

```
Containerfile              ← podman build recipe (builder + runtime stages)
Makefile                   ← shared build system: build/sync everywhere, deploy in consumers
TAGS                       ← image build config for THIS repo (consumers keep their own)
scripts/fedora-setup.sh    ← host setup: GRUB, tuned, podman-compose IPC patch
```

Every consuming project (e.g. `llamacpp-qwen3.8-27b`) includes this repo as a
**git submodule + symlinks** and keeps its own per-project `TAGS` + deployment
files. `llamacpp-qwen3.8-27b` is a complete, working reference — follow the
setup guide below to create a new one.

## Setting up a new consuming project

Create a project `<name>` (e.g. `llamacpp-deepseek-v4-flash-0731`) that builds
and runs its own model on the shared image recipe. **`<name>` is the container
name**: the Makefile derives it from `IMAGE_NAME`'s basename
(`localhost/<name>` → `<name>`), and the quadlet files must be named after it —
keep `IMAGE_NAME`, the quadlet dir/files, and the container name consistent.

### 0. One-time host prerequisites (per machine, not per project)

Skip this if the machine already runs a project (e.g. `qwen3.8-27b`) — both
steps are already done. Run each once, from a checkout of `llamacpp-shared`:

```sh
# Host tuning: GRUB, tuned profile, podman-compose IPC patch (see the script)
sudo bash scripts/fedora-setup.sh

# The HuggingFace token is a shared podman secret, created once and reused by
# every project's container as HF_TOKEN:
printf '%s' "$HF_TOKEN" | podman secret create huggingface-token -
```
> Skip the secret if `podman secret ls` already lists `huggingface-token`.

### 1. Create the project repo

```sh
mkdir -p ~/Desktop/fedora/<name> && cd ~/Desktop/fedora/<name>
git init
```

### 2. Add the shared submodule

```sh
git submodule add git@github.com:nicholasburr/llamacpp-shared.git llamacpp-shared
```

### 3. Symlink the shared files into the project

```sh
ln -s llamacpp-shared/Containerfile Containerfile
ln -s llamacpp-shared/Makefile Makefile
mkdir -p scripts
ln -s ../llamacpp-shared/scripts/fedora-setup.sh scripts/fedora-setup.sh
```
> Only these are symlinked. `TAGS` is **not** symlinked — each project keeps
> its own (it holds the per-project `IMAGE_NAME` + `MODEL`).

### 4. Write the project's `TAGS`

The image tag is computed by the Makefile as `<LLAMA_TAG>-rocm-<ROCM_VERSION>`
(never hand-typed). Set `IMAGE_NAME` and `MODEL` for the project:

```
IMAGE_NAME=localhost/<name>
LLAMA_TAG=v0.6.0
ROCM_VERSION=10.1.0
FEDORA_VERSION=44
MODEL=<org>/<model>-GGUF:<quant>
```

### 5. Write the deployment files

Two equivalent ways to run the container (same name / image / port 8000 /
devices / IPC / volumes / env). Pick one — both are kept in lockstep with
`TAGS` by `make sync`. Copy from the working example (`llamacpp-qwen3.8-27b/`)
and change the model + name:

- **Quadlet (default — user systemd, no root):**
  `config/containers/systemd/<name>/<name>.build` and `<name>.container`.
  Change the container name, `Image=localhost/<name>:<tag>`, and the
  `LLAMA_ARG_HF_REPO` model ref; in `.build` also set `SetWorkingDirectory`
  (absolute path to *this* project) and the `BuildArg=` values (match `TAGS`).
- **podman compose (operator alternative):** `compose.yaml`. Change `image:`,
  `container_name:`, and `LLAMA_ARG_HF_REPO`.

> Both target the same production slot (container `<name>` on :8000).
> Run exactly ONE at a time.

### 6. Add a `.gitignore`

```
.DS_Store
*~
*.swp
__pycache__/
*.log
tmp/
```

### 7. Build, deploy, verify

```sh
make build     # localhost/<name>:<LLAMA_TAG>-rocm-<ROCM_VERSION>
make deploy    # quadlet only: install the units + start <name>.service
make status    # confirm the container is up
make logs      # follow the logs
```
> `make deploy`/`logs`/`stop`/`clean` are real here; in this repo they are
> no-ops (there is no model container to manage).

### 8. Commit

```sh
git add .gitmodules llamacpp-shared Containerfile Makefile scripts/fedora-setup.sh \
        TAGS config compose.yaml .gitignore
git commit -m 'Initial <name> deployment on the shared llamacpp image'
```

## Updating a consumer after a change here

```sh
cd <consumer-project>
git submodule update --remote llamacpp-shared   # or: cd llamacpp-shared && git pull
git add llamacpp-shared
git commit -m 'Bump llamacpp-shared: <what changed>'
git push --recurse-submodules=on-demand
```

## Ongoing: change the model or image version

```sh
make parametric-build TAG=<v-or-b-tag>   # pin a new llama.cpp tag in TAGS
# (or edit TAGS by hand: LLAMA_TAG / ROCM_VERSION / FEDORA_VERSION / MODEL)
make sync && make build && make deploy   # rewrite deploy files, rebuild, redeploy
```
`make sync` rewrites the image tag + build args + model ref across the deploy
files so they never drift from `TAGS`, and tags git HEAD with the image tag.

## Conventions

- `TAG` and `REPO` stay **build args** in the Containerfile — each consumer
  pins its own llama.cpp version (via its `TAGS` file / `BuildArg=TAG=`).
- Keep the shared files at these exact paths; consumers symlink to them.
- Consumers keep their own `TAGS` (per-project `IMAGE_NAME`, `MODEL`, versions);
  the shared `TAGS` only configures this repo's own `make build` / `make sync`.
- `make deploy`/`logs`/`stop`/`clean` are full recipes in consumers but graceful
  no-ops in this repo (there is no model container here to deploy or stop).
- Bump the pinned commit in consumers deliberately: a consumer build is
  reproducible only because the submodule pin is part of its commit.
