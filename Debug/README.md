# Debug app testing

Only app-behavior tools remain: model selection, review prompts, reward/reset
controls and local Screen Time/shield diagnostics. These implementations remain
`#if DEBUG`; production blocking and recording-health monitoring are unchanged.

Screenshot/session collection, Photos export, dataset transfers, the labeler URL
handler, motion/video experiments and their Live Activity have moved to the
standalone Slowth Dev repository. There is no capture/upload implementation in
this directory or in any Slowth host/extension, even in Debug. Old preference
values cannot reactivate it. Existing local recordings are not deleted or copied
to another application's container.

`project.yml` is the source membership definition. Regenerate with
`xcodegen generate` after changes. `scripts/verify_no_research_code.py` checks
source and every app/extension executable, including `.debug.dylib`; it applies
to Debug and Release. `scripts/verify_app_configuration.py` also calls it.

```sh
python3 scripts/verify_no_research_code.py
python3 scripts/verify_no_research_code.py --app /path/to/Unscroll.app
```

Xcode Canvas previews remain for app behavior and ordinary feature/help cards.
Simulator presentation fixtures do not start capture, request permissions or
change blocking settings. Compilation is separate from device behavior checks.
