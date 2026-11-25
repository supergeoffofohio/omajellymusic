# OmaJelly Music

Browse and play music from a Jellyfin server directly from the Omarchy bar. The compact player shows album art, the current track, artist, and album. Playback continues when you close the popup.

This project builds on [Hopelezz’s Omajelly](https://github.com/Hopelezz/omajelly), itself based on [Omaplex](https://github.com/pjgeutjens/omarchy-omaplex). See the [original license](LICENSE).

## Install and connect

You need Omarchy Quattro with the schema version 1 plugin API, Python 3.11 or newer, mpv, secret-tool, a desktop secret service, and a Jellyfin account with access to music.

**Existing Omajelly users:** both versions currently use the plugin ID `io.github.hopelezz.omajelly` and the same installation directory. Choose one version for that slot. Back up local edits before switching.

```bash
omarchy plugin add https://github.com/supergeoffofohio/omajellymusic.git --enable
```

Right-click the bar icon to open connection settings. Enter your Jellyfin base URL, choose **Get a Quick Connect code**, and authorize the code from a signed-in Jellyfin client.

## Use the player

- Open an album artist, then an album. Click a track to play it individually or **Play album** to queue the album in disc and track order.
- Click the bar icon during playback to open Now Playing. Use the transport controls to pause, resume, or change tracks.
- Click **Queue** to see the track list and jump to another song. Choose **Library** to browse and **Now Playing** to return to the current track.

For a Macro Deck play/pause button, run this command as the desktop user. Use the full home directory path if your launcher does not expand `~`.

```bash
/usr/bin/python ~/.config/omarchy/plugins/io.github.hopelezz.omajelly/music_helper.py play-pause
```
