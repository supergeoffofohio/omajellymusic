# OmaJelly Music

Browse and play music from a Jellyfin server directly from the Omarchy bar. The compact player shows album art, the current track, artist, and album. Playback continues when you close the popup.

This project builds on [Hopelezz’s Omajelly](https://github.com/Hopelezz/omajelly), itself based on [Omaplex](https://github.com/pjgeutjens/omarchy-omaplex). See the [original license](LICENSE).

## Install and connect

OmaJelly Music is distributed under the [MIT license](LICENSE).

You need Omarchy Quattro with the schema version 1 plugin API, Python 3.11 or newer, mpv, secret-tool, a desktop secret service, and a Jellyfin account with access to music.

OmaJelly Music uses its own plugin ID, `io.github.supergeoffofohio.omajellymusic`. If you used the earlier music fork in the original Omajelly slot, install this version separately, sign in once, and update any existing Macro Deck button using the commands below. Your previous installation and its credentials stay in their original slot.

```bash
omarchy plugin add https://github.com/supergeoffofohio/omajellymusic.git --enable
```

Right-click the bar icon to open connection settings. Enter your Jellyfin base URL, choose **Get a Quick Connect code**, and authorize the code from a signed-in Jellyfin client.

## Remove the plugin

To also clear the saved Jellyfin connection, open connection settings and choose **Remove credentials**, then **Confirm remove**, before uninstalling. Save any local edits to the installed plugin checkout that you want to keep.

Run the following as your regular desktop user and confirm the removal prompt:

```bash
omarchy plugin remove io.github.supergeoffofohio.omajellymusic
```

## Use the player

- Open an album artist, then an album. Click a track to play it individually or **Play album** to queue the album in disc and track order.
- From **Album artists**, choose **Playlists**, open a saved Jellyfin playlist, and click **Play playlist**. Audio tracks play in saved order, including repeats. Now Playing and Macro Deck show each track’s own title, artist, album, and artwork.
- Click the bar icon during playback to open Now Playing. Use the transport controls to pause, resume, or change tracks.
- Click **Queue** to see the track list and jump to another song. Choose **Library** to browse and **Now Playing** to return to the current track.

## Desktop media controls

During playback, OmaJelly Music publishes the track, artist, album, local cover image, duration, and playback position through MPRIS under the player name `omajellymusic`. Desktop media controls use `python-gobject`, included with Omarchy Quattro. You can use all tray controls directly.

## Optional Macro Deck button

Start an album or playlist. In Macro Deck on the same desktop, add a **Music Player** widget and select OmaJelly Music if listed, or **System Media – Any app**. Choose **Full cover** and enable the title, artist, album, and timeline as desired. With **Any app**, other active players may also supply the display.

With `playerctl` installed on the Macro Deck host, assign each gesture a **Run Command** action:

| Gesture | Command |
| --- | --- |
| Short press to pause or resume | `/usr/bin/playerctl --player=omajellymusic play-pause` |
| Long press to advance the queue | `/usr/bin/playerctl --player=omajellymusic next` |

To check what Macro Deck can display, run `playerctl --player=omajellymusic metadata` while a track is playing.

Earlier versions stored downloaded videos under `$XDG_CACHE_HOME/omajellymusic/downloads` (normally `~/.cache/omajellymusic/downloads`). The music widget no longer lists or plays those files. They remain on disk until you move or delete them yourself.
