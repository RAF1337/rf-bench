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
      expected-failures.json
    variants/alt/        alternative correct solution (required by the validator)
```

`variants/bad` and `variants/alt` are complete apps (`app.json` plus source) with the same app id
as `solution/app`.

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

## Validation

`pwsh src/Test-Task.ps1 -Task Tnnn` grades the task's apps with the real grader (container and
compiler folder required) and checks that:

- `solution/app` is fully right;
- `solution/variants/alt` is fully right;
- `solution/variants/bad` compiles and passes all functional tests, and the checks that fail are
  exactly the ones in `variants/bad/expected-failures.json`. Its budget results are reported but
  not required, because a planted standards violation may legitimately cost SQL;
- for `bugfix` and `feature` tasks, `assignment/app` is not fully right.

`expected-failures.json` is a non-empty JSON array of check names, each one listed in
`checks.json`, for example `["RequiresSetLoadFieldsBeforeRead", "NoFindMinus"]`.

Exit codes: 0 valid, 1 task invalid, 2 validator error (configuration, Docker, compiler or grader
infrastructure). Each graded app uses its own grader folder under `<TempRoot>\validate\<taskId>`.
Pass `-SwitchDocker` to switch Docker to Windows containers for the run and back to Linux after.
