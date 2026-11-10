# Speed Alert

Warns you before **speed cameras** and **speed bumps** with voice messages
(for example at 500 m, 300 m, 200 m and 100 m), on a custom Google Map.

## Setup (one time)

### 1. Google Maps API key
1. Go to <https://console.cloud.google.com/> → create a project.
2. Turn on **Maps SDK for Android** and **Maps SDK for iOS**.
3. Create an API key (Credentials → Create credentials → API key).
4. Put the key in the app:
   - **Android:** in `android/local.properties`, set `MAPS_API_KEY=AIza...`
   - **iPhone:** copy `ios/Flutter/Secrets.xcconfig.example` to
     `ios/Flutter/Secrets.xcconfig` and set `MAPS_API_KEY = AIza...`

   Both files are ignored by git, so the key is never uploaded to GitHub.

Without a key the app still runs, but the map is grey.

### 2. Warning sounds (optional)
Without any setup, the phone's voice says each warning. To change it, use
**Settings → Warning sounds** in the app (see below). To ship default
recordings inside the app instead, put them in `assets/sounds/`; the file
names are listed in [assets/sounds/README.md](assets/sounds/README.md).

### 3. Backend (community map, backup, moderation)
The server is in [backend/](backend/README.md) (Node.js + MySQL). To run it on
this computer:
```sh
cd backend && cp .env.example .env && npm install
docker compose up -d db && npm run dev      # http://localhost:3000
npm run create-admin -- you@example.com "a long password"   # admin panel: /admin
```
The app works without it (everything is saved on the phone first and
uploaded when the server is reachable).

### 4. Run
```sh
flutter run                                   # simulator / emulator → local backend
flutter run --dart-define=API_URL=http://192.168.1.20:3000   # real phone → your computer's IP
flutter build apk --dart-define=API_URL=https://api.yourdomain.com   # release
```

## Online features
- **Community map:** points you add are shared with drivers nearby (turn off
  per point with *Share with other drivers*, or for all new points in
  Settings → Account & sync). Points from other drivers download for about
  30 km around you and keep working offline.
- **Still there / Gone:** tap another driver's point to vote or *Report a
  problem*. Three "gone" votes take it off the map; reports go to the
  moderators.
- **Backup:** Settings → Account & sync → *Back up with email*. On a new phone,
  *I already have an account* brings back your points and settings (sound
  files stay on the old phone).
- **Moderation:** sign in at `http://<server>/admin` with an account made by
  `npm run create-admin`.

## How to use
- **Long-press the map** → add a camera or bump at that spot (type, speed
  limit, and which driving direction it applies to).
- **Tap Add** → the full form opens at your current location (type, speed
  limit, direction, sound). Choose *Map center* under Location to put it
  where the map is instead. After saving, the map zooms to the new pin.
- **Tap a point** → edit, delete, give it its own sound, or **Test drive**.
  Test drive pretends to drive past it (20 km/h over the limit) so you can
  hear all the warnings at home.
- **Hold and drag a point** → move it. The message that appears has **Undo**.
- **Settings** → warning distances, "slow down" tolerance, warning sounds,
  mute, appearance (Auto = light by day, dark at night), import/export of
  points.

### Changing the warning sounds
In **Settings → Warning sounds**:
- Tap **Speed camera**, **Speed bump** or **"Slow down"** and pick any sound
  file (MP3, M4A, WAV…) or a video (only its sound plays). The app keeps its
  own copy, so it still works if you delete the original.
- **Plays 1×–5×** sets how many times the warning plays in a row.
- **Different sound for each distance** lets you use, for example, one sound
  at 500 m and another at 100 m.
- To give **one place** its own sound (one camera only), tap that point on
  the map → *Warning sound*. It can also have its own repeat count.

Which sound plays: the point's own sound → your sound for that distance →
your sound for all distances → recordings in `assets/sounds/` → phone voice.
Sounds longer than 15 seconds are cut off so the next warning isn't delayed.
If the phone can't play a file, the app says so when you pick it.

### Importing a list of points
Copy text like this, then Settings → *Import from clipboard*:
```
33.3152, 44.3661, camera, 80
33.3201, 44.3705, bump
33.3302, 44.3800, camera, 60, 90
```
Columns: `lat, lng, type (camera|bump), speed limit, direction in degrees`.
Only lat and lng are required. JSON from *Export* also works.

## How the warnings work
- Only points **in front of you** warn (not behind, not to the side).
- If a point has a direction, it only warns when you drive that way (so the
  camera on the other side of the highway stays quiet).
- Each distance is said once. After you pass a point it resets, so the next
  time you drive there it warns again.
- Near a camera with a speed limit, going over the limit plays the
  "slow down" warning (at most every 10 s) and turns the screen red.
- It keeps working with the screen off or another app open (Android shows a
  notification; iPhone shows the blue location pill).

## Code map
| File | What it does |
|------|--------------|
| `lib/services/alert_engine.dart` | Decides when to warn (tested in `test/alert_engine_test.dart`) |
| `lib/services/sync_service.dart` | Uploads my points and settings, downloads the community map, sign in / out (tested in `test/sync_service_test.dart`) |
| `lib/services/api_client.dart` | Talks to the backend (`API_URL`) |
| `backend/` | Node.js + MySQL server and admin panel ([backend/README.md](backend/README.md)) |
| `lib/services/voice_player.dart` | Plays the warnings one at a time (your sounds, recordings or phone voice), with repeats |
| `lib/services/sound_resolver.dart` | Decides which sound a warning uses (tested in `test/sound_resolver_test.dart`) |
| `lib/services/sound_library.dart` | Picks sound / video files and keeps copies inside the app |
| `lib/widgets/sound_controls.dart` | Sound picker sheet, sound rows and repeat chips |
| `lib/services/location_service.dart` | GPS + test drive simulation |
| `lib/theme/app_theme.dart` | All app colors and button/sheet styles — edit to re-skin the app |
| `lib/widgets/hud.dart` | Warning banner, speed gauge, status pill |
| `lib/map/map_styles.dart` | Map colors — edit to customize the map |
| `lib/map/marker_icons.dart` | Camera / bump icons drawn in code |
| `lib/screens/map_screen.dart` | Main screen |
| `lib/screens/settings_screen.dart` | Settings |

## Before publishing
- Change the app id `com.example.new_project` (Android `build.gradle.kts`,
  iOS bundle id in Xcode).
- Restrict the Maps API key to your app in Google Cloud Console.
- Speed camera warning apps are not allowed in some countries — check the
  rules where you publish.
