# Flow

Minimaler Foto- und Video-Viewer für macOS, entstanden als radikaler Ersatz für FlowVision (netdcy/FlowVision). Neu geschrieben, kein Code übernommen. Öffentlich als github.com/Wiredframe/flow.

Umfang bewusst klein halten: ein Ordner, quadratisches Raster, neueste zuerst, Vorschaubilder gecacht, ausgewähltes Video spielt mit Ton in Schleife in seiner Kachel. Keine Sortier-, Layout- oder Stiloptionen ergänzen, ohne dass der Nutzer es ausdrücklich will.

## Bauen und starten

`./build.sh` baut `build/Flow.app` (SwiftPM, AppKit, macOS 14+) und signiert mit „Apple Development: info@wiredframe.de“. Die feste Signatur ist nötig, sonst fragt macOS nach jedem Build erneut nach dem Zugriff auf externe Laufwerke, und `contentsOfDirectory` blockiert bis dahin still.

## Release

`./release.sh` baut mit „Developer ID Application“ (nicht notarisiert, es gibt kein notarytool-Profil) und packt `build/Flow-<version>.zip` per `ditto --noextattr --norsrc`. Version steht in `Info.plist`. Danach Commit `Version x.y.z`, Tag `vx.y.z`, `gh release create`. Zuletzt im Tap `~/Projekte/Claude Code/homebrew-tap` in `Casks/flow.rb` version und sha256 anpassen, Commit `flow x.y.z`.

## Aufbau

- `Folder.swift`: Ordner einlesen (`FolderScanner`), Änderungen beobachten (`FolderWatcher`)
- `ThumbnailCache.swift`: quadratische 640-px-JPEGs unter `~/Library/Caches/de.wiredframe.Flow/Thumbnails`, Speicher-Cache, Vorab-Erzeugung im Hintergrund, Aufräumen ab 2 GB
- `GridViewController.swift`: Raster, Auswahl, Video-Wiedergabe, Quick Look (Leertaste, Doppelklick), Menübefehle
- `Tile.swift`: Kachel mit Bild, Player-Layer, Auswahlring, Dateiname

Einstellungen in `UserDefaults` (`de.wiredframe.Flow`): `showNames`, `tileSize`, `muted`, `lastFolder`.

## Icon

`Resources/AppIcon.icns` ist selbst gezeichnet: `swift Tools/make-icon.swift <ordner.iconset>`, dann `iconutil -c icns <ordner.iconset> -o Resources/AppIcon.icns`. Das frühere Icon von macosicons.com war nur für den privaten Gebrauch frei.
