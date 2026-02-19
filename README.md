# repogen

Safe-by-default, spec-driven repository scaffolder in PowerShell 7.5.

## Safety defaults
- Default command is `plan` (dry-run).
- `apply` requires both the `apply` subcommand and `--yes`.
- Existing output roots are blocked unless `--allow-existing-root` is set.
- Conflicts default to `fail`.
- Overwrite requires both `--on-conflict overwrite` and `--force`.
- All writes are path-checked to remain under `--output`.
- Optional `--allow-path` glob allowlist can further restrict writes.

## Usage
```bash
pwsh ./repogen.ps1 --help
pwsh ./repogen.ps1 validate --spec ./examples/spec.example.json
pwsh ./repogen.ps1 plan --spec ./examples/spec.example.json --output ./out
pwsh ./repogen.ps1 apply --spec ./examples/spec.example.json --output ./out --yes
pwsh ./repogen.ps1 apply --spec ./examples/spec.shopping-agent.json --output ./shopping-agent --yes
```

## Commands
- `validate --spec <file> [--strict] [--schema <ignored>] [--format text|json]`
- `plan --spec <file> --output <dir> [--format text|json] [--on-conflict fail|skip|overwrite|prompt] [--allow-path <glob>...] [--plan-out <file>]`
- `apply --spec <file> --output <dir> --yes [--allow-existing-root] [--on-conflict ...] [--force] [--allow-path ...] [--plan-out <file>]`

If no command is provided, `plan` is used.

## Exit codes
- `0` success
- `2` validation/usage/safety error
- `3` conflict detected
- `4` required template component missing
- `5` unexpected internal error

## Tests
```bash
pwsh ./tests/run-tests.ps1
```
