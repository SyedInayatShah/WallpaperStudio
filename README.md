<h1 align="center">Wallpaper Studio</h1>

<p align="center">
  Live, dynamic and still wallpapers for macOS and Windows.<br>
  Photos, GIFs, videos and whole scenes that follow the time of day.
</p>

---

## Download

### Mac

| Your Mac | Download |
| --- | --- |
| **Apple silicon** (M1, M2, M3, M4) | [**Wallpaper-Studio.zip**](https://github.com/SyedInayatShah/WallpaperStudio/releases/latest/download/Wallpaper-Studio.zip) |

1. Unzip it and drag **Wallpaper Studio** into your **Applications** folder.
2. Double-click it. macOS will refuse to open it — that is normal, the app is not from the App Store.
3. Open **System Settings → Privacy & Security**, scroll down, press **Open Anyway** next to Wallpaper Studio, and confirm.
4. Say **yes** when it asks for permission to change your wallpaper. Without that it cannot do its job.

You do that once. After it the app keeps itself up to date — there is nothing to download again.

Needs macOS 13 or later. Intel Macs are not supported.

### Windows

| Your PC | Download |
| --- | --- |
| **Most PCs** (Intel or AMD) | [**WallpaperStudio-Windows-x64.exe**](https://github.com/SyedInayatShah/WallpaperStudio/releases/latest/download/WallpaperStudio-Windows-x64.exe) |
| **Windows on ARM** (Snapdragon, Surface Pro X and friends) | [**WallpaperStudio-Windows-arm64.exe**](https://github.com/SyedInayatShah/WallpaperStudio/releases/latest/download/WallpaperStudio-Windows-arm64.exe) |

Needs Windows 10 (version 1809 or later) or Windows 11. Nothing else to install.

## What it does

- **Live wallpapers** — your own videos and GIFs playing behind your icons, with sound if you want it.
- **Dynamic wallpapers** — scenes your computer draws live, following the real clock: bright at midday, lit windows and stars at night.
- **Explore** — a library of original wallpapers made for this app, downloaded straight into yours.
- **Rotation** — change wallpaper on a schedule, in your own order or shuffled, saved as named sets.
- **Menu-bar button** — switch wallpaper without opening the app.

## Signing in

The Mac app asks for your email once and sends a sign-in link. Click it, the app opens signed in, you pick a username, and that is the last you see of it.

## What else is in here

Besides the app, this repository holds the Explore library the app downloads from: `stills/`, `live/` and `dynamic/` with `catalog.json` listing them, and `app/version.json`, which is how installed copies find new versions.
