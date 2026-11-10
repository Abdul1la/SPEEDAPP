# Built-in voice recordings

> **You don't need this folder to change the sounds.** In the app, go to
> **Settings → Warning sounds** and pick any audio file or video from the
> phone. You can also give a single point its own sound: tap it on the
> map → *Warning sound*. Sounds picked in the app always win over the files
> here.
>
> Use this folder only for recordings you want to ship inside the app
> (the default for everyone who installs it).

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
4. the phone's voice.

After adding files here, stop the app and run it again (hot reload is not
enough).
