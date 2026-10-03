# Native build verification — 2026-10-03

## Initial integrated run

- Commit: `91fc3eb444deb155220fbeabb98ded47eec90fee`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37092453068.
- macOS completed source checkout, public overlay, compatibility assembly and all source/plugin checks.
- Native service, plugin, history, settings-transfer, translation, privacy, account, appearance, media and player suites passed.
- Native localization, backend and voice suites stopped at compilation. The IPA build was not reached.

The reported compilation failures were:

1. `WhitegramSettingsState` needed an explicit public zero-argument initializer for the SettingsUI module.
2. The nested profile-fetch callback required explicit `self` for its session/cache properties.
3. The empty audio-buffer test needed an `Int16` element type after the new Float overload was introduced.

These are addressed in the follow-up commit; its native results must be checked separately. No device or authenticated-service pass is implied.
