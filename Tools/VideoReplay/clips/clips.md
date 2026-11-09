# VideoReplay clips

Text only. No footage, frames or screenshots of footage are committed or
redistributed; clips live in `~/CueSyncClips/<clip-name>/` outside every git
repo and are re-created with the commands below. Only the hand-marked
`corners.json` files are in the repo.

Licence: all three sources are standard-YouTube-licence uploads (yt-dlp
reports no Creative Commons licence). They are used locally, for offline
evaluation of the detector and planner only. Do not publish frames or
renders made from them.

| clip name (folder) | source | segment | table / camera |
| --- | --- | --- | --- |
| `pub-green-7ft-topdown` | https://www.youtube.com/watch?v=PAG4RzGYyR8 ("9 Ball Pool Runout, English 8 Ball Table", LuckyPants Pool, a vertical Short, 680x720 native) | 0:10 to 0:40 | pub table, green cloth, elevated near-top-down fixed camera, phone-like; size marked `sevenFoot` (an estimate: English pub table) |
| `speedpool-bluecloth` | https://www.youtube.com/watch?v=QMoeTKm4sfY ("Lightning-Fast 8-Ball Run Out!", The Routine Instructor, Short, 720x1280) | 0:00 to 0:30 | bar table, light-blue cloth, low oblique fixed camera, busy garage background with timer overlay and "SPEED POOL" title burnt in; size marked `sevenFoot` (an estimate) |
| `home-9ft-breakrun` | https://www.youtube.com/watch?v=IgtYtAeUecc ("8 Ball BREAK AND RUN ... (9 Foot Table)", Bang Time Pool, Short, 720x1280) | 0:00 to 0:30 | home 9 ft table, tan cloth, low oblique fixed camera across the room; size per the upload title (`nineFoot`) |

## Reproduce a clip

yt-dlp on this Mac could only fetch the webm (vp9/opus) formats of Shorts; the
avc1 and landscape formats returned HTTP 403. Per clip (`ID`, `START`, `END`
from the table, `NAME` = the folder name):

```
mkdir -p ~/CueSyncClips/NAME/frames ~/CueSyncClips/NAME/out
yt-dlp -f "bv*[height<=1280][ext=webm]+ba[ext=webm]" -o ~/CueSyncClips/NAME/full.%\(ext\)s "https://www.youtube.com/watch?v=ID"
ffmpeg -ss START -to END -i ~/CueSyncClips/NAME/full.webm -c:v libx264 -crf 20 -an ~/CueSyncClips/NAME/clip.mp4
ffmpeg -i ~/CueSyncClips/NAME/clip.mp4 -vf fps=2 ~/CueSyncClips/NAME/frames/f%04d.png
cp Tools/VideoReplay/clips/NAME/corners.json ~/CueSyncClips/NAME/corners.json
```

Frames are 2 fps PNGs (`f0001.png` is the first frame at the segment start;
60 frames per clip).

## corners.json

Pixel coordinates in the 2 fps frame PNG (top-left origin) of the four
playing-field corners (cushion noses), order c0, c1, c2, c3 with c0 to c1 a
long edge (see `ClipConfig.swift`). They were placed by eye on a frame and
checked by rendering the quad over several frames, so each has a few pixels
of error. The cameras are fixed, so one set per clip is used for all frames.
