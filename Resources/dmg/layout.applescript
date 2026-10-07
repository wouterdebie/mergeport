on run argv
    set mountPath to item 1 of argv
    tell application "Finder"
        set volumeFolder to disk of (POSIX file (mountPath & "/.background") as alias)
        open volumeFolder
        tell container window of volumeFolder
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set pathbar visible to false
            set bounds to {180, 140, 780, 532}
        end tell
        set viewOptions to icon view options of container window of volumeFolder
        tell viewOptions
            set arrangement to not arranged
            set icon size to 96
            set text size to 13
            set label position to bottom
            set shows item info to false
            set shows icon preview to true
            set background picture to POSIX file (mountPath & "/.background/background.tiff")
        end tell
        set position of item "Mergeport.app" of volumeFolder to {150, 185}
        set position of item "Applications" of volumeFolder to {450, 185}
        set extension hidden of item "Mergeport.app" of volumeFolder to true
        update volumeFolder without registering applications
        delay 3
        close container window of volumeFolder
        delay 2
        open volumeFolder
        delay 2
        tell container window of volumeFolder
            if current view is not icon view then error "Finder did not save icon view"
            if toolbar visible then error "Finder did not hide the toolbar"
            if statusbar visible then error "Finder did not hide the status bar"
            if pathbar visible then error "Finder did not hide the path bar"
            if bounds is not {180, 140, 780, 532} then error "Finder did not save window bounds"
        end tell
        if position of item "Mergeport.app" of volumeFolder is not {150, 185} then error "Incorrect app icon position"
        if position of item "Applications" of volumeFolder is not {450, 185} then error "Incorrect Applications icon position"
        close container window of volumeFolder
        delay 2
    end tell
end run
