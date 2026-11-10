# Built-in voice recordings

> **You don't need this folder to change the sounds.** In the app, go to
> **Settings → Warning sounds** and pick a built-in sound, or any audio
> file or video from the phone. You can also give a single point its own
> sound: tap it on the map → *Warning sound*. Sounds picked in the app
> always win over the files here.
>
> Use this folder only for recordings you want to ship inside the app
> (the default for everyone who installs it).

## Built-in sounds (`tones/`)

The sounds listed in **Settings → Warning sounds** (original sounds made
for this app, see `lib/models/warning_tone.dart`):

| File                    | Name        | Default for  |
|-------------------------|-------------|--------------|
| tones/chime.wav         | Chime       | speed camera |
| tones/alert.wav         | Alert       |              |
| tones/radar.wav         | Radar       |              |
| tones/ding.wav          | Ding        |              |
| tones/bump.wav          | Bump-bump   | speed bump   |
| tones/double_beep.wav   | Double beep |              |

After the sound, the phone voice says the distance (Settings → *Say the
distance too*). To add one, put the file in `tones/` and add it to
`WarningTone`.

## Recordings

File names (use .mp3, .m4a or .wav):

| File              | When it plays                         |
|-------------------|---------------------------------------|
| camera_500.mp3    | Speed camera 500 m ahead              |
| camera_300.mp3    | Speed camera 300 m ahead              |
| camera_200.mp3    | Speed camera 200 m ahead              |
| camera_100.mp3    | Speed camera 100 m ahead              |
| bump_300.mp3      | Speed bump 300 m ahead                |
| bump_100.mp3      | Speed bump 100 m ahead                |
| camera.mp3        | (optional) any camera distance without its own file |
| bump.mp3          | (optional) any bump distance without its own file   |
| over_speed.mp3    | You are over the speed limit          |

If you change the warning distances in Settings (for example to 400 m),
name the file to match: camera_400.mp3.

Order used for each warning:

1. the point's own sound (set on that one point),
2. your sound from Settings for that distance, then for all distances,
3. the files in this folder (`camera_300.mp3`, then `camera.mp3`),
4. the built-in sound chosen in Settings (`tones/`), then the voice,
5. the phone's voice.

After adding files here, stop the app and run it again (hot reload is not
enough).
