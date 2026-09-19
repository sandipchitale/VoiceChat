# Running VoiceChat

## Build & install

```bash
./Scripts/make-app.sh release      # or: debug
cp -R .build/VoiceChat.app /Applications/   # optional: run from a stable path
```

`make-app.sh` compiles `voicechatd` + `voicechat-mcp`, assembles
`.build/VoiceChat.app`, and ad-hoc signs it. A real bundle is required: macOS
only grants Microphone + Speech Recognition (TCC) to a signed bundle whose
`Info.plist` carries the usage descriptions.
