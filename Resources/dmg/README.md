# Native drag-to-Applications installer

From the repository root (macOS 14+, Xcode Command Line Tools):

```sh
bash scripts/make-dmg.sh "dist/Mergeport.app" "dist/Mergeport.dmg"
bash scripts/check-dmg.sh "dist/Mergeport.dmg"
bash Resources/dmg/test-packaging.sh "dist/Mergeport.app"
```

Both interfaces accept absolute or relative paths. The builder refuses existing
outputs, including symlinks; the app must already have a valid signature
(ad-hoc signing is sufficient for local/CI checks). It never signs, notarizes,
launches, quits, or replaces the source app. Release identity and notarization
remain separate release steps.

## Deterministic styling without Finder in CI

`layout.dmg` is a small, compressed HFS+ filesystem containing an Applications
symlink, `.DS_Store`, and a hidden Retina background. Its saved Finder window is
600 × 392 points, icon view, 96-point icons, 13-point labels; the app is at
(150, 185), Applications at (450, 185). The light background includes explicit drag
instructions, an arrow, and instructions for opening the installed app.

The builder expands a private copy of this filesystem, preserves its catalog
IDs and volume identity (required for Finder's background alias), uses `ditto`
to add the app without damaging framework symlinks/signatures, and compresses
to read-only UDZO. There is **no unstyled fallback** and no GUI dependency during
release/CI builds. `create-dmg` was evaluated as the interactive reference;
`scripts/Brewfile` declares it as an optional design tool, not a CI prerequisite.
CI on the `xcode-27` runner only needs the commands above, after building/signing the app.

The checker verifies image checksums/format, exact reference Finder metadata
and background, parsed window/icon settings, native background-alias resolution,
the Applications symlink, root contents, and `codesign --verify --deep --strict`.
It mounts a private image copy read-only, so it never adopts or ejects a user's
existing mount. If an identical template is already mounted, alias resolution
may use that mount: the checker requires identical volume UUID, background
catalog ID, relative path, and background bytes. Expected hidden HFS+ system
directories are allowed; unexpected installer items are rejected.

All scratch files live in UUID-named directories inside the project/output
directory, not system temporary directories. Traps detach only their own mount.
On a detach failure, staging is retained with an actionable diagnostic rather
than deleting files through a live mount. The output is published only after
all checks pass.

## Regenerating the layout

This is an **interactive authoring task**, not a release or CI step. Finder must
be running, and Terminal may need permission to automate Finder. Do not regenerate
the template merely to release a new app version.

1. Edit `render-background.swift` or `layout.applescript`.
2. Run:
   ```sh
   swift Resources/dmg/render-background.swift
   tiffutil -cathidpicheck Resources/dmg/background.png \
     Resources/dmg/background@2x.png -out Resources/dmg/background.tiff
   ```
3. Move the existing `layout.dmg` aside (the authoring tool refuses overwrite).
4. Run `bash Resources/dmg/create-template.sh "dist/Mergeport.app"`.
   This automates only a private image's Finder window, checks its settings,
   saves `Finder.DS_Store`, and removes only the copied placeholder app.
5. Rebuild a preview, run the checker/regression tests, and visually inspect the
   window on a Retina display. Commit `layout.dmg`, `Finder.DS_Store`, the TIFF,
   and updated sources together. The intermediate PNG files are not needed.

`verify-layout.swift` deliberately converts Finder's legacy Carbon alias record
to a bookmark using Apple's supported conversion API; recent SDKs may print its
deprecation warning. No deprecated API is used to create or modify the app.
