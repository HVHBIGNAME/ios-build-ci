"""Read-only source integration. Native behavior suites live in tests/privacy."""

from collections import Counter
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import content_control_patches as content
from source_patches import SourcePatches

OVERLAY = Path(__file__).resolve().parents[1]
SOURCE = os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE")


def in_memory(files):
    patches = SourcePatches(Path(SOURCE or "."))
    patches.original.update(files)
    patches.pending.update(files)
    return patches


class PrivacySourceTests(unittest.TestCase):
    def test_runtime_registry_resolves_only_owned_sources(self):
        self.assertEqual(len(content.PRIVACY_RUNTIME_FILES), len(set(content.PRIVACY_RUNTIME_FILES.values())))
        for name in content.PRIVACY_RUNTIME_FILES:
            self.assertTrue((OVERLAY / "cleanroom" / name).is_file(), name)

    def test_new_sources_parse(self):
        from tree_sitter import Language, Parser
        import tree_sitter_swift
        parser = Parser(Language(tree_sitter_swift.language()))
        paths = [OVERLAY / "cleanroom" / name for name in content.PRIVACY_RUNTIME_FILES]
        paths.extend((OVERLAY / "tests/privacy").glob("*.swift"))
        for path in paths:
            with self.subTest(path=path.name):
                tree = parser.parse(path.read_bytes())
                stack, errors = [tree.root_node], []
                while stack:
                    node = stack.pop()
                    if node.type == "ERROR" or node.is_missing:
                        errors.append(f"{node.start_point.row + 1}:{node.start_point.column + 1} {node.type}")
                    stack.extend(node.children)
                self.assertFalse(errors, errors)


@unittest.skipUnless(SOURCE, "set WHITEGRAM_ASSEMBLED_SOURCE for read-only integration")
class ContentControlIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.patches = SourcePatches(Path(SOURCE))
        with patch.object(Path, "write_bytes") as writes, patch.object(Path, "write_text") as text_writes:
            content.content_control_patches(cls.patches)
        writes.assert_not_called()
        text_writes.assert_not_called()

    def test_second_pass_is_idempotent(self):
        repeated = in_memory(self.patches.pending)
        with patch("content_control_patches.SourcePatches", return_value=repeated), patch.object(Path, "write_bytes") as writes:
            report = content.apply_privacy_patches(Path(SOURCE))
        writes.assert_not_called()
        self.assertEqual(repeated.pending, self.patches.pending)
        self.assertEqual(report, {key: sorted(value) for key, value in self.patches.features.items()})

    def test_late_missing_or_duplicate_anchor_never_writes_earlier_files(self):
        target = content.COMPONENTS + "VideoMessageCameraScreen/Sources/VideoMessageCameraScreen.swift"
        anchor = "                if self.cameraState.isViewOnceEnabled {\n                    attributes.append(AutoremoveTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil))"
        installed = "                if WhitegramContentPolicy.recordAsViewOnce(requested: self.cameraState.isViewOnceEnabled, eligible: self.viewOnceAvailable && scheduleTime == nil) {\n                    attributes.append(AutoremoveTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil))"
        for duplicate in (False, True):
            files = dict(self.patches.original)
            files[target] = files[target].replace(installed, anchor)
            self.assertEqual(files[target].count(anchor), 1)
            files[target] = files[target] + "\n" + anchor if duplicate else files[target].replace(anchor, "unrecognized view-once implementation")
            staged = in_memory(files)
            with self.subTest(duplicate=duplicate), patch("content_control_patches.SourcePatches", return_value=staged), patch.object(Path, "write_bytes") as writes:
                with self.assertRaisesRegex(ValueError, "ghostModeRecordOnce"):
                    content.apply_privacy_patches(Path(SOURCE))
                writes.assert_not_called()

    def test_mixed_installation_is_rejected(self):
        path = content.CORE + "State/SynchronizePeerReadState.swift"
        files = dict(self.patches.pending)
        files[path] += "\nif WhitegramGhost.suppressReadReceipts {\n"
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            content.content_control_patches(in_memory(files))

    def test_local_export_does_not_enable_protocol_forwarding_or_editing(self):
        menu = self.patches.pending[content.UI + "ChatInterfaceStateContextMenus.swift"]
        self.assertIn("let isCopyProtected = chatPresentationInterfaceState.copyProtectionEnabled || message.isCopyProtected()", menu)
        self.assertIn("if !isLocalCopyProtected && isWhiteGramMessageContextOptionEnabled", menu)
        forward = menu.split("if data.messageActions.options.contains(.forward),", 1)[1].split("\n        }", 1)[0]
        self.assertIn("if !isCopyProtected", forward)
        self.assertNotIn("isLocalCopyProtected", forward)
        self.assertNotIn(content.CORE + "Utils/MessageUtils.swift", self.patches.pending)
        self.assertNotIn(content.CORE + "PendingMessages/EnqueueMessage.swift", self.patches.pending)

    def test_restriction_bypass_is_evaluated_per_reason_without_discarding_other_rules(self):
        for path in (
            content.CORE + "Utils/PeerUtils.swift",
            "submodules/PlatformRestrictionMatching/Sources/PlatformRestrictionMatching.swift",
        ):
            with self.subTest(path=path):
                value = self.patches.pending[path]
                self.assertIn("WhitegramContentSettings.shouldBypassRestriction(reason: rule.reason)", value)
                self.assertNotIn("if WhitegramContentSettings.bypassContentRestrictions { return nil }", value)
                self.assertIn("return rule.text", value)
                self.assertIn("contentSettings.ignoreContentRestrictionReasons.contains(rule.reason)", value)

    def test_call_confirmation_precedes_call_manager_and_has_no_recursion(self):
        value = self.patches.pending[content.UI + "AccountContext.swift"]
        wrapper = value.split("public func requestCall(peerId:", 1)[1].split("private func whitegramRequestConfirmedCall", 1)[0]
        self.assertNotIn("callManager?.requestCall", wrapper)
        self.assertIn("confirmation.resolve(confirmed: false)", wrapper)
        self.assertIn("confirmation.resolve(confirmed: true)", wrapper)
        self.assertNotIn("self.requestCall(", wrapper)
        confirmed = value.split("private func whitegramRequestConfirmedCall", 1)[1]
        self.assertIn("endCurrentIfAny: false", confirmed)
        self.assertIn("endCurrentIfAny: true", confirmed)

    def test_original_story_prompt_defers_both_avatar_routes_until_confirmation(self):
        value = self.patches.pending["submodules/ChatListUI/Sources/ChatListController.swift"]
        avatar = value.split("self.chatListDisplayNode.mainContainerNode.openStories =", 1)[1].split("self.chatListDisplayNode.peerContextAction", 1)[0]
        self.assertLess(avatar.index("whitegramOpenStoriesWithGhostPrompt"), avatar.index("StoryContainerScreen.openArchivedStories"))
        self.assertIn("}, open: { [weak self, weak itemNode] in", avatar)
        self.assertEqual(avatar.count("StoryContainerScreen.openPeerStories("), 1)
        helper = (OVERLAY / "cleanroom/WhitegramContentStoryPrompt.swift").read_text(encoding="utf-8")
        for key in ("title", "text", "open", "enable"):
            self.assertIn(f'"stories.ghostPrompt.{key}"', helper)
        self.assertIn('prepare: { WhitegramContentSettings.set(true, for: "disableStoryReadReceipts") }', helper)
        self.assertIn("confirmation.resolve(confirmed: false)", helper)
        self.assertNotIn('for: "ghostModeEnabled"', helper)

    def test_location_override_reaches_initial_read_and_updates_and_uses_a_real_picker(self):
        value = self.patches.pending["submodules/LocationUI/Sources/LocationMapNode.swift"]
        self.assertIn("self.whitegramLocationOverride ?? self.mapView?.userLocation.location", value)
        self.assertIn("self.locationPromise.set(.single(self.whitegramLocationOverride ?? location))", value)
        self.assertIn("self.locationPromise.set(.single(Optional(location)))", value)
        self.assertIn("self.locationPromise.set(.single(self.currentUserLocation))", value)
        self.assertIn("NotificationCenter.default.removeObserver(observer)", value)
        picker = (OVERLAY / "cleanroom/WhitegramContentLocationController.swift").read_text(encoding="utf-8")
        self.assertIn("LocationPickerController(context: context, style: .glass, mode: .pick,", picker)
        self.assertIn("WhitegramContentLocation.set(latitude: location.latitude, longitude: location.longitude)", picker)
        self.assertIn("//submodules/LocationUI:LocationUI", content.PRIVACY_REQUIRED_DEPENDENCIES["SettingsUI"])

    def test_receipt_suppression_keeps_local_cleanup_and_pts_require_a_real_response(self):
        path = content.CORE + "State/ManagedConsumePersonalMessagesActions.swift"
        value = self.patches.pending[path]
        for action in ("consumeUnseenPersonalMessage", "readReactionOrPollVote"):
            anchor = f"transaction.setPendingMessageAction(type: .{action}, id: id, action: nil)"
            self.assertEqual(value.count(anchor), self.patches.original[path].count(anchor))
        self.assertEqual(value.count("peerId: id.peerId)"), 4)
        self.assertEqual(value.count("Signal<Api.Bool?, NoError>"), 2)
        self.assertNotIn("return .single(.boolFalse)", value)
        self.assertEqual(value.count("if let result = result {"), self.patches.original[path].count("if let result = result {"))

    def test_read_actions_snapshot_visible_bounds_and_reset_on_thread_navigation(self):
        history = self.patches.pending[content.UI + "ChatHistoryListNode.swift"]
        helper = history.split("func whitegramReadOnActionSignal()", 1)[1].split("private func beginReadHistoryManagement", 1)[0]
        self.assertIn("self.whitegramVisibleReadIndex", helper)
        self.assertIn("self.canReadHistoryValue", helper)
        self.assertIn("self.chatLocation.peerId == index.id.peerId", helper)
        self.assertIn("threadId: location.threadId", helper)
        self.assertIn("let location = self.chatLocation", helper)
        self.assertIn("self.whitegramVisibleReadIndex = nil", history)
        core = (OVERLAY / "cleanroom/WhitegramReadAction.swift").read_text(encoding="utf-8")
        self.assertIn("permit.consume(for: scope)", core)
        self.assertNotIn("WhitegramPreferences.set", core)
        self.assertNotIn("Int32.max", core)
        self.assertNotIn("|> restart", core)
        self.assertNotIn("readMessageContents(", core)
        self.assertNotIn("stories.", core)

    def test_ghost_local_read_exception_is_carried_only_by_the_bound_action(self):
        peer = self.patches.pending[content.CORE + "TelegramEngine/Messages/ApplyMaxReadIndexInteractively.swift"]
        self.assertIn("whitegramReadAction: Bool = false", peer)
        self.assertIn("if !whitegramReadAction && WhitegramGhost.suppressLocalHistoryRead(for: index.id.peerId) { return }", peer)
        thread = self.patches.pending[content.CORE + "TelegramEngine/Messages/ReplyThreadHistory.swift"]
        self.assertIn("whitegramReadActionThreadId: whitegramReadActionThreadId)", thread)
        self.assertIn("messageIndex.id.peerId != self.peerId || whitegramReadActionThreadId != self.threadId", thread)
        context = self.patches.pending[content.UI + "AccountContext.swift"]
        helper = context.split("func whitegramLocalReadAction(", 1)[1].split("public func applyMaxReadIndex", 1)[0]
        self.assertLess(helper.index("let context = chatLocationContext"), helper.index("return { context.applyMaxReadIndex"))
        core = (OVERLAY / "cleanroom/WhitegramReadAction.swift").read_text(encoding="utf-8")
        self.assertLess(core.index("permit.consume(for: scope)"), core.index("applyLocalRead()"))
        self.assertLess(core.index("applyLocalRead()"), core.index("guard WhitegramGhost.canReadOnAction"))

    def test_queued_secret_content_reads_still_preserve_sequence_slots_per_peer(self):
        secret = self.patches.pending[content.CORE + "State/ManagedSecretChatOutgoingOperations.swift"]
        self.assertEqual(secret.count("WhitegramGhost.suppressReadReceipts(for: peerId) ?"), 5)
        for layer in (46, 73, 101, 144):
            self.assertIn(f"return .layer{layer}(.decryptedMessageService(randomId: actionGloballyUniqueId, action: WhitegramGhost.suppressReadReceipts(for: peerId) ? .decryptedMessageActionNoop", secret)
        self.assertIn("boxedDecryptedSecretMessageAction(action: action, peerId: peerId)", secret)

    def test_history_receipts_recheck_privacy_after_async_peer_loading(self):
        value = self.patches.pending[content.CORE + "State/SynchronizePeerReadState.swift"]
        self.assertEqual(value.count("if WhitegramGhost.suppressAutomaticHistoryReads(for: peerId) { return .single(readState) }"), 2)
        for body in value.split("|> mapToSignal { inputPeer -> Signal<PeerReadState, PeerReadStateValidationError> in")[1:]:
            self.assertLess(body.index("WhitegramGhost.suppressAutomaticHistoryReads"), body.index("network.request("))

    def test_privacy_refresh_restores_requested_presence_instead_of_reusing_suppression(self):
        value = self.patches.pending[content.CORE + "State/ManagedAccountPresence.swift"]
        self.assertIn("self.updatePresence(self.whitegramRequestedOnline)", value)
        self.assertNotIn("self.updatePresence(self.wasOnline)", value)
        update = value.split("private func updatePresence(_ isOnline: Bool)", 1)[1]
        self.assertLess(update.index("self.whitegramRequestedOnline = isOnline"), update.index("WhitegramGhost.effectiveOnlineStatus(requested: isOnline)"))

    def test_retention_precedes_consumption_without_disabling_timers_or_service_actions(self):
        path = content.CORE + "TelegramEngine/Messages/MarkMessageContentAsConsumedInteractively.swift"
        value = self.patches.pending[path]
        self.assertLess(value.index("WhitegramContentMedia.captureBeforeConsumption"), value.index("ConsumableContentMessageAttribute(consumed: true)"))
        for marker in ("AutoremoveTimeoutMessageAttribute(timeout: timeout, countdownBeginTime: timestamp)", "AutoclearTimeoutMessageAttribute(timeout: timeout, countdownBeginTime: timestamp)", ".readMessagesContent(layer:", "TelegramMediaExpiredContent(data:"):
            self.assertEqual(value.count(marker), self.patches.original[path].count(marker))
        media = (OVERLAY / "cleanroom/WhitegramContentMedia.swift").read_text(encoding="utf-8")
        self.assertIn("mediaBox.completedResourcePath(resource)", media)
        self.assertNotIn("fetchedResource", media)
        self.assertNotIn("network.request", media)

    def test_media_download_observers_are_bound_to_viewing_and_disposed_with_the_owner(self):
        preview = self.patches.pending[content.GALLERY + "SecretMediaPreviewController.swift"]
        playlist = self.patches.pending[content.COMPONENTS + "MediaManager/PeerMessagesMediaPlaylist/Sources/PeerMessagesMediaPlaylist.swift"]
        for value in (preview, playlist):
            self.assertEqual(value.count("WhitegramContentMedia.observeViewedMedia("), 1)
            self.assertEqual(value.count("self.whitegramRetainedMediaDisposable.dispose()"), 1)
            self.assertLess(value.index("WhitegramContentMedia.observeViewedMedia("), value.index("self.context.engine.messages.markMessageContentAsConsumedInteractively("))
        media = (OVERLAY / "cleanroom/WhitegramContentMedia.swift").read_text(encoding="utf-8")
        self.assertIn("mediaBox.resourceData(resource)", media)
        self.assertIn("|> filter { $0.complete && $0.size > 0 }", media)
        self.assertIn("|> take(1)", media)
        self.assertIn("guard shouldRetain(message) else { return }", media)
        photos = (OVERLAY / "cleanroom/WhitegramContentPhotoExporter.swift").read_text(encoding="utf-8")
        after_authorization = photos.split("let authorized: (PHAuthorizationStatus) -> Void", 1)[1]
        self.assertLess(after_authorization.index("guard WhitegramContentSettings.saveViewOnceMedia"), after_authorization.index("performChanges("))

    def test_voice_and_privacy_recording_hooks_compose_and_replay_in_both_orders(self):
        import voice_patches

        composed = None
        for transforms in (
            (content.content_control_patches, voice_patches.voice_patches),
            (voice_patches.voice_patches, content.content_control_patches),
        ):
            with self.subTest(first=transforms[0].__name__):
                staged = SourcePatches(Path(SOURCE))
                with patch.object(Path, "write_bytes") as writes, patch.object(Path, "write_text") as text_writes:
                    for transform in transforms:
                        transform(staged)
                    first = dict(staged.pending)
                    for transform in reversed(transforms):
                        transform(staged)
                    self.assertEqual(staged.pending, first)
                writes.assert_not_called()
                text_writes.assert_not_called()
                recording = staged.pending[voice_patches.CHAT]
                self.assertEqual(recording.count("let viewOnce = WhitegramContentPolicy.recordAsViewOnce("), 2)
                self.assertEqual(recording.count("whitegramProcessedAudio: ChatInterfaceMediaDraftState.Audio? = nil"), 1)
                self.assertIn("viewOnce: viewOnce, messageEffect: messageEffect, postpone: postpone, whitegramProcessedAudio: processed)", recording)
                self.assertIn("whitegramProcessedAudio.map { .audio($0) } ?? recordedMediaPreview", recording)
                self.assertIn("whitegramProcessedAudio == nil && self.whitegramPrepareAudioDraft(audio,", recording)
                self.assertIn("self.whitegramCanSendViewOnceRecording(scheduleTime: scheduleTime)", recording)
                self.assertIn("guard scheduleTime == nil, self.subject != .scheduledMessages,", recording)
                self.assertIn("self.presentationInterfaceState.sendPaidMessageStars == nil,", recording)
                self.assertIn("peer.id != self.context.account.peerId && peer.botInfo == nil", recording)
                self.assertIn("readAction: self.chatDisplayNode.historyNode.whitegramReadOnActionSignal()", recording)
                video = staged.pending[voice_patches.VIDEO]
                self.assertIn("eligible: self.viewOnceAvailable && scheduleTime == nil", video)
                self.assertIn("WhitegramVoiceVideo.process(", video)
                self.assertIn("data: whitegramVideo.data, synchronous: true", video)
                if composed is not None:
                    self.assertEqual(staged.pending, composed)
                composed = dict(staged.pending)

    def test_banned_channel_retention_keeps_server_membership_and_rights(self):
        value = (OVERLAY / "cleanroom/WhitegramContentPolicy.swift").read_text(encoding="utf-8")
        for field in ("participationStatus", "adminRights", "bannedRights", "accessHash", "flags"):
            self.assertIn(f"{field}: updated.{field}", value)
        updates = self.patches.pending[content.CORE + "UpdatePeers.swift"]
        self.assertIn("case .left:\n                            transaction.updatePeerChatListInclusion(peerId, inclusion: .notIncluded)", updates)
        self.assertIn("case .kicked where WhitegramContentSettings.keepBannedChats:", updates)
        self.assertIn("title: previous.title", value)

    def test_banned_channels_stay_open_read_only_without_the_delete_banner(self):
        value = self.patches.pending[content.UI + "ChatControllerContentData.swift"]
        self.assertIn("updatedChannel.participationStatus == .kicked {\n                        shouldDismiss = !WhitegramContentSettings.keepBannedChats", value)
        self.assertIn("updatedGroup.membership == .Removed {\n                        shouldDismiss = true", value)
        panels = self.patches.pending[content.UI + "ChatInterfaceStateInputPanels.swift"]
        self.assertIn("case .kicked:\n                if WhitegramContentSettings.keepBannedChats { return (nil, nil) }", panels)
        self.assertIn("case .member:\n                isMember = true", panels)

    def test_transformed_swift_has_no_new_parser_errors(self):
        from tree_sitter import Language, Parser
        import tree_sitter_swift
        parser = Parser(Language(tree_sitter_swift.language()))

        def errors(value):
            encoded = value.encode("utf-8")
            root = parser.parse(encoded).root_node
            found = Counter()
            stack = [root]
            while stack:
                node = stack.pop()
                if node.type == "ERROR" or node.is_missing:
                    found[(node.type, encoded[node.start_byte:node.end_byte])] += 1
                stack.extend(node.children)
            return found

        for path, value in self.patches.pending.items():
            with self.subTest(path=path):
                self.assertFalse(errors(value) - errors(self.patches.original[path]))


if __name__ == "__main__":
    unittest.main()
