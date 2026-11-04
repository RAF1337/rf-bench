# Task format

Each task lives in `tasks/<ID>/` where `<ID>` is `Tnnn` (for example `T001`).

```
tasks/T001/
  task.json
  assignment/            copied to the agent workspace; the only part the agent sees
    TASK.md              required
    app/app.json         required for bugfix and feature; app/src must not exist for greenfield
    app/src/...          starter source (bugfix, feature)
  solution/              never visible to the agent
    app/                 reference solution app (app.json required)
    tests/               functional and Budget_ tests (app.json required)
    checks.json          required
    variants/bad/        deliberately wrong solution (required by the validator)
    variants/alt/        alternative correct solution (required by the validator)
```

## task.json

| Field | Description |
| --- | --- |
| `id` | Must equal the folder name. |
| `title` | Short title. |
| `type` | `bugfix`, `feature` or `greenfield`. |
| `difficulty` | `easy`, `medium` or `hard`. |
| `area` | Free text functional area. |
| `categories` | Subset of: `data-access`, `locking-isolation`, `transactions`, `architecture`, `naming-style`, `ui`, `error-handling`. |
| `timeoutMinutes` | Optional per-task timeout. |

## checks.json

An array of `{ "check": "<name>", "category": "<category>", "params": { ... } }`. `check` must be a name returned by `Get-AlCheckNames`; `category` must be one of the fixed categories.

## App ids and object ranges

- `assignment/app/app.json` has the same `id` as `solution/app/app.json`, so the agent's app is the one graded and the test app depends on it.
- Task `Tnnn` uses app object ids `50000 + nnn*100` to `+99`, and test app object ids `70000 + nnn*100` to `+99`.

## Loader errors

`Get-BenchTask` throws `"<taskId>: <problem>"` for any violation above.
