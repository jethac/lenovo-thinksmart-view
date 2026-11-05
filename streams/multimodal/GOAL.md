# multimodal: conversations, the camera and the video codec

## Goal

Straylight holds a real conversation, not one exchange per wake word, and can
look: a photo on request, or a short stretch of video when the question is
about something happening in front of it. The model (`meta/muse-spark-open`
through ai&) takes images; the tablet's job is to send only what the question
needs, and to use its own hardware (the S5KC505A camera, the Venus codec) to
get there.

## Done means

### 1. Conversation

- After a reply, Straylight keeps listening for a follow-up without the wake
  word, for a short window shown on the screen; silence, a closing phrase, or
  a tap ends the conversation and returns to idle.
- The conversation is managed, not just the last few turns: what is kept,
  summarised or dropped is decided by a stated policy (turn count, token
  budget, idle time), images are dropped from the context after their turn
  and replaced by the model's own description, and the user can start a new
  conversation from the screen or by voice.
- The screen shows the conversation, not just the last reply.
- Interrupting a reply (barge-in) is only in scope once echo cancellation
  works (`devices/echo-cancellation`); until then the follow-up window opens
  when speech ends.

### 2. Camera

- The camera produces usable colour images on the running baseline kernel:
  debayered, exposure and white balance under control, at least a 640x480 to
  1304x980 stream at 6 fps or better and a full-resolution still, JPEG
  encoded, with CPU and memory measured beside the live services.
- The lens cover is respected: no capture while it is closed, and the screen
  says so.
- The camera runs only on an explicit action (the photo button, a video
  request); the screen shows clearly whenever it is on. Nothing is stored or
  sent without that action.

### 3. Video codec

- Venus is enabled on 7.3 and verified with frame counts, not just a started
  process: H.264 and HEVC decode, and H.264 encode from camera frames.
  The B-frame limit is reproduced and explained (firmware or driver).
- Its use is measured: what encoding or decoding on Venus saves against the
  CPU for the paths below.

### 4. Seeing, sparingly

- **Photo:** an add-photo button with a countdown; the photo goes with the
  next question (or the current one) at a resolution chosen for the model, not
  the sensor.
- **Video:** frames sampled at about 6 fps on the tablet, but only frames
  that carry change (motion, a new object, a gesture across frames) are sent,
  within a fixed per-turn budget of images and bytes; the budget and the
  selection rule are measured against what the model needs to answer.
- Whether ai& takes images (and video) for `meta/muse-spark-open`, in what
  format, and at what token cost per image, is measured before the budget is
  set.

## Rules

- `WORKSTREAMS.md` applies: device lock, the live assistant stays up, kernel
  tests through `kernel/deploy-to-device.sh`, the baseline restored after.
- Camera rail voltages from `devices/camera/BRIEF.md` are binding.
- Images and video from the device are captures: they stay out of every
  repository.

## Current state (2026-11-04)

- Conversation: the listener keeps the last 6 turns in memory and drops them
  after 300 s idle, but every turn needs the wake word, and the screen shows
  one reply.
- Camera: the S5KC505A driver is in the baseline (`kernel/patches/0401`-`0403`);
  raw RAW10 frames at 2608x1960 (30 fps), 1304x980 and 1936x1096 are verified.
  No ISP, no libcamera.
- Venus: worked on the earlier 6.19.5 port (1080p H.264 1.26x real time,
  HEVC 5.74x, B-frames stall); not enabled on 7.3.
- ai&: the `chat` command takes text messages only.
