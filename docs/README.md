# Documentation

1. [Install Scripts](./install_docs.md) — per-script breakdown of `install_deps.sh` → `install_verify.sh`
2. [Configuration Files](./config_files.md) — `config.sh`, `common.sh`, `build.env`, `vm_config.template.json`, `.env`
3. [Function Setup Scripts](./function_scripts.md) — launching microVMs, invoking functions, the concurrency model, SAAF experiments
4. [Power Measurement Scripts](./power_scripts.md) — the `power-scripts/` collectors and the `fc_experiment.sh` / `fc_analyze_pkg.py` pipeline

For install steps and copy-pasteable run commands, see the [root README](../README.md#install--run) — this is the one canonical walkthrough; don't duplicate it here.

For the concurrency model (what's shared vs. per-instance across N microVMs), see [Function Setup Scripts § Concurrency model](./function_scripts.md#concurrency-model).
