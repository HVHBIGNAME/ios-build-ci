# Simulator startup checks (build 34644)

The supplied physical-device crash described build 34639 entering CloudKit.
`configure.py` disables iCloud in the sideload build, and `test_configure.py`
checks propagation into the actual build configuration generator. No new
physical-device crash report has been received for 34643.

The build workflow now also builds the same assembled source with
`release_sim_arm64`, applies WhiteGram's bundle postprocessing and runs
`simulator_smoke.py` on an available iPhone simulator. The first simulator build
adds compilation time; subsequent runs can reuse the Bazel disk cache.

The check creates its own simulator and performs a fresh-install launch and a
relaunch, observing each process for 30 seconds. An immediate exit, later exit,
changed process identity, missing screenshot, failed command or cleanup error
fails the check. Missing runtimes are failures, not skips. Only the simulator
created by this invocation is shut down and deleted.

`WhiteGram-simulator-launch-<revision>` contains `launch-report.json`, screenshots,
stdout/stderr and process-filtered system logs. Review the screenshots separately:
process survival alone does not establish a responsive or correct UI. Simulator
build failures before the runner starts are recorded in the Actions build log.
The device IPA and matching symbols are uploaded before the simulator check, so
their presence alone does not mean the startup check passed.

This check uses a fresh simulator with no signed-in account and a separate
simulator binary. It does not validate the re-signed device IPA, account-dependent
screens, arbitrary user actions, background termination, or a specific iPhone/iOS
version. Physical-device launch confirmation is still required.

Local automation regressions: `python -B -m unittest discover -s whitegram/tests -p test_simulator_smoke.py`.
The actual simulator check requires macOS/Xcode and is pending its first CI run.
