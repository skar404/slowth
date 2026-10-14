#!/usr/bin/env python3
"""iOS pause bundle integration for all build configurations. Never edit shared WebExt or macOS resources."""
import argparse
import json
from pathlib import Path
import shutil


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Pause integration anchor changed: ' + old[:80])
    return text.replace(old, new, 1)


def prepare(source, adapter, bundle):
    # Start from pristine inputs so repeated builds are idempotent.
    for relative in ['manifest.json', 'background.js', 'content/common.js']:
        destination = bundle / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, destination)
    manifest = json.loads((source / 'manifest.json').read_text())
    manifest['background']['scripts'].insert(1, 'pause-policy.js')
    manifest['background']['scripts'].insert(-1, 'pause-background.js')
    for script in manifest['content_scripts']:
        script['js'].insert(1, 'pause-policy.js')
    (bundle / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    for filename in ['pause-policy.js', 'pause-background.js']:
        shutil.copy2(adapter / filename, bundle / filename)
    background = (source / 'background.js').read_text()
    background = replace_once(background,
        'const settings = ns.normalizeSiteSettings(site, state.toggles?.[site]);',
        'const settings = ns.pauseSettings(site, state, ns.normalizeSiteSettings(site, state.toggles?.[site]));')
    background = replace_once(background,
        'const state = await ns.getStateCached();',
        'const state = await ns.getStateCached(site);')
    background = replace_once(background,
        '(async () => sendResponse(await ns.getStateCached()))();',
        '''(async () => {
        let site = null;
        try { site = getHostKey(new URL(sender?.url || sender?.tab?.url || "").hostname); } catch (_) {}
        sendResponse(await ns.getStateCached(site));
      })();''')
    (bundle / 'background.js').write_text(background)
    content = (source / 'content/common.js').read_text()
    content = replace_once(content, '    function applyState(state) {\n      if (!state) return;', '''    let pauseBaseState = null;
    function applyState(state) {
      if (!state) {
        if (!pauseBaseState) return;
        state = {...pauseBaseState, pause: null};
      }
      pauseBaseState = state;''')
    content = replace_once(content,
        'const settings = ns.normalizeSiteSettings(site, state.toggles?.[site]);',
        'const settings = ns.pauseSettings(site, state, ns.normalizeSiteSettings(site, state.toggles?.[site]));')
    content = replace_once(content,
        '    window.addEventListener("focus", refresh);', '''    window.addEventListener("focus", refresh);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState !== "hidden") {
        if (pauseBaseState && !ns.pauseValid(pauseBaseState, site)) applyState(pauseBaseState);
        refresh();
      }
    });
    // Visible-page deadlines are a second check, never a background guarantee.
    setInterval(() => {
      if (pauseBaseState?.pause?.id && !ns.pauseValid(pauseBaseState, site)) {
        applyState({...pauseBaseState, pause: null});
      }
    }, 250);
    setInterval(() => {
      if (document.visibilityState !== "hidden" && pauseBaseState?.pause?.id) refresh();
    }, 2000);''')
    (bundle / 'content/common.js').write_text(content)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['source', 'adapter', 'bundle']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    prepare(Path(args.source), Path(args.adapter), Path(args.bundle))
