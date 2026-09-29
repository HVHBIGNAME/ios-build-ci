"""Run with -B; fixtures, integration edits and second passes stay in memory.

WHITEGRAM_ASSEMBLED_SOURCE enables read-only integration against the assembled
tree. WHITEGRAM_PUBLIC_SOURCE additionally checks restored-helper provenance.
"""

import collections
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from public_api_adaptations import (
    CHAT,
    CHAT_LIST_CONTROLLER,
    PASSKEYS_SCREEN,
    TRANSLATE_SCREEN,
    TRANSLATION_HELPERS,
    adapt_community_selection,
    adapt_message_reactions,
    adapt_passkey_credential_identity,
    adapt_translation_button,
    adapt_translation_sheet,
    apply_public_api_adaptations,
)
from source_patches import SourcePatches


ROOT = Path(__file__).resolve().parent / "in-memory-assembly"
BUBBLE = CHAT + "ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift"
ANIMATED = CHAT + "ChatMessageAnimatedStickerItemNode/Sources/ChatMessageAnimatedStickerItemNode.swift"
STICKER = CHAT + "ChatMessageStickerItemNode/Sources/ChatMessageStickerItemNode.swift"


def reaction_fixture(message: str) -> str:
    arm = f"""        case .reaction:
            if canAddMessageReactions(message: {message}) {{
                item.controllerInteraction.updateMessageReaction({message}, .default, false, nil)
            }} else {{
                item.controllerInteraction.openMessageContextMenu({message}, false, self, subFrame, nil, nil)
            }}
"""
    # A short replacement with count=2 would incorrectly match these two
    # upstream calls and skip the two still-unadapted fork switch arms.
    stock = """if canAddMessageReactions(message: EngineMessage(item.message)) {
    item.controllerInteraction.updateMessageReaction(item.message, .default, false, nil)
}
"""
    return stock * 2 + arm * 2


TRANSLATION_BUTTON = """let buttonSize = translateButtonNode.update(presentationData: item.presentationData, controllerInteraction: item.controllerInteraction, chatLocation: item.chatLocation, subject: item.associatedData.subject, message: item.message, account: item.context.account, disableComments: true, isTranslate: true)
        item.controllerInteraction.expandedTranslationMessageStableIds.insert(item.message.stableId)
        item.controllerInteraction.requestMessageUpdate(item.message.id, false)
                if !hasTranslation {
                    item.controllerInteraction.expandedTranslationMessageStableIds.remove(item.message.stableId)
                }
                item.controllerInteraction.requestMessageUpdate(item.message.id, false)
item.controllerInteraction.requestMessageUpdate(item.message.id, false, customTransition)
historyNode.requestMessageUpdate(messageId)
"""

COMMUNITY_SELECTION = """                    if case .community = peer {
                        self.openCommunityView(communityId: peer.id)
                        self.chatListDisplayNode.mainContainerNode.currentItemNode.clearHighlightAnimated(true)
                        return
                    }
                    self.context.sharedContext.navigateToChatController(params)
"""

PASSKEY_REMOVAL = """            guard self.passkeysData?.contains(where: { $0.id == id }) == true else {
                return
            }
            let _ = component.context.engine.auth.deletePasskey(id: id).startStandalone()

            self.passkeysData?.removeAll(where: { $0.id == id })
            component.passkeysDataUpdated(self.passkeysData ?? [])
            self.state?.updated(transition: .spring(duration: 0.4))

            #if compiler(>=6.2)
            if #available(iOS 26.0, *), let passkey = self.passkeysData?.first(where: { $0.id == id }) {
                Task { @MainActor in
                    let updater = ASCredentialUpdater()
                    if let credentialId = decodeBase64(passkey.id) {
                        try await updater.reportUnknownPublicKeyCredential(relyingPartyIdentifier: "telegram.org", credentialID: credentialId)
                    }
                }
            }
            #endif
"""

TRANSLATION_SHEET = """import TelegramUIPreferences
import Markdown
import ViewControllerComponent

private let translateToTag = GenericComponentViewTag()

switch self.translationService {
case .gTranslate:
    return alternativeTranslateText(text: text, fromLang: fromLang, toLang: toLang)
case .telegram:
    return self.context.engine.messages.translate(text: text, toLang: toLang, entities: entities, tone: self.tone)
    |> `catch` { _ -> Signal<(String, [MessageTextEntity])?, TranslationError> in
        return alternativeTranslateText(text: text, fromLang: fromLang, toLang: toLang)
    }
}

let controller = TranslateScreen(context: context, forceTheme: forceTheme, text: text, entities: entities, canCopy: canCopy, fromLanguage: fromLang, toLanguage: toLang, ignoredLanguages: ignoredLanguages, replaceText: replaceText)
controller.pushController = pushController ?? { _ in }
controller.presentController = presentController ?? { _ in }
presentController?(controller)
"""


def fixture_files() -> dict[str, str]:
    return {
        BUBBLE: reaction_fixture("target.message") + TRANSLATION_BUTTON,
        ANIMATED: reaction_fixture("item.message"),
        STICKER: reaction_fixture("item.message"),
        CHAT_LIST_CONTROLLER: COMMUNITY_SELECTION,
        PASSKEYS_SCREEN: PASSKEY_REMOVAL,
        TRANSLATE_SCREEN: TRANSLATION_SHEET,
    }


def pending_patches(files: dict[str, str]) -> SourcePatches:
    patches = SourcePatches(ROOT)
    patches.original.update(files)
    patches.pending.update(files)
    return patches


def run_in_memory(files: dict[str, str]):
    written = {}

    def read_text(path, *, encoding):
        return files[path.relative_to(ROOT).as_posix()]

    def write_bytes(path, data):
        written[path.relative_to(ROOT).as_posix()] = data.decode("utf-8")
        return len(data)

    with patch.object(Path, "read_text", read_text), patch.object(Path, "write_bytes", write_bytes):
        report = apply_public_api_adaptations(ROOT)
    return files | written, written, report


class PublicApiAdaptationsTests(unittest.TestCase):
    def test_reaction_predicates_wrap_raw_messages_but_callbacks_stay_raw(self):
        patches = pending_patches(fixture_files())
        adapt_message_reactions(patches)
        for path, message in ((BUBBLE, "target.message"), (ANIMATED, "item.message"), (STICKER, "item.message")):
            with self.subTest(path=path):
                value = patches.pending[path]
                self.assertEqual(value.count(f"case .reaction:\n            if canAddMessageReactions(message: EngineMessage({message}))"), 2)
                self.assertNotIn(f"canAddMessageReactions(message: {message})", value)
                self.assertIn(f"updateMessageReaction({message}, .default, false, nil)", value)
                self.assertIn(f"openMessageContextMenu({message}, false, self, subFrame, nil, nil)", value)
                self.assertNotIn("EngineMessage(EngineMessage", value)

    def test_partial_reaction_migration_is_not_mistaken_for_complete(self):
        files = fixture_files()
        files[ANIMATED] = files[ANIMATED].replace(
            "case .reaction:\n            if canAddMessageReactions(message: item.message)",
            "case .reaction:\n            if canAddMessageReactions(message: EngineMessage(item.message))",
            1,
        )
        patches = pending_patches(files)
        with self.assertRaisesRegex(ValueError, "expected 2 anchors, found 1"):
            adapt_message_reactions(patches)

    def test_translation_button_passes_engine_message_and_account_peer_id(self):
        patches = pending_patches(fixture_files())
        adapt_translation_button(patches)
        first_line = patches.pending[BUBBLE].split("let buttonSize = ", 1)[1].splitlines()[0]
        self.assertIn("message: EngineMessage(item.message), accountPeerId: item.context.account.peerId", first_line)
        self.assertNotIn("account: item.context.account", first_line)
        self.assertTrue(first_line.endswith("disableComments: true, isTranslate: true)"))

    def test_message_update_closure_gets_third_argument_without_changing_method_defaults(self):
        patches = pending_patches(fixture_files())
        adapt_translation_button(patches)
        value = patches.pending[BUBBLE]
        self.assertEqual(value.count("requestMessageUpdate(item.message.id, false, nil)"), 2)
        self.assertNotIn("requestMessageUpdate(item.message.id, false)", value)
        self.assertIn("requestMessageUpdate(item.message.id, false, customTransition)", value)
        self.assertIn("historyNode.requestMessageUpdate(messageId)", value)

    def test_translation_helpers_restore_language_selection_and_speech_controls(self):
        patches = pending_patches(fixture_files())
        adapt_translation_sheet(patches)
        value = patches.pending[TRANSLATE_SCREEN]
        for declaration in (
            "public func languageSelectionController(",
            "final class PlayPauseIconComponent:",
            "private final class GiftViewContextReferenceContentSource:",
        ):
            self.assertEqual(value.count(declaration), 1)
        self.assertIn("import ItemListUI\n", value)
        self.assertIn("import ManagedAnimationNode\n", value)
        self.assertIn("environment: ComponentFlow.Environment<Empty>", value)
        self.assertNotIn("environment: Environment<Empty>", value)
        self.assertIn("completion(state.fromLanguage, state.toLanguage)", value)
        self.assertIn("updated.fromLanguage = code", value)
        self.assertIn("updated.toLanguage = code", value)
        self.assertIn("startFrame: 41, endFrame: 83", value)
        self.assertIn("referenceView: self.sourceView, contentAreaInScreenSpace: UIScreen.main.bounds", value)
        self.assertIn(TRANSLATION_SHEET.split("switch self.translationService", 1)[1].split("let controller =", 1)[0], value)

    def test_language_selection_reopens_sheet_with_whole_chat_callback(self):
        patches = pending_patches(fixture_files())
        adapt_translation_sheet(patches)
        value = patches.pending[TRANSLATE_SCREEN]
        self.assertIn("fromLanguage: fromLang, toLanguage: toLang, ignoredLanguages: ignoredLanguages, replaceText: replaceText, translateChat: translateChat)", value)
        self.assertIn("controller.pushController = pushController ?? { _ in }", value)
        self.assertIn("controller.presentController = presentController ?? { _ in }", value)

    def test_older_restored_helpers_upgrade_without_duplicate_declarations(self):
        current, _, _ = run_in_memory(fixture_files())
        old = dict(current)
        old[TRANSLATE_SCREEN] = old[TRANSLATE_SCREEN].replace("ComponentFlow.Environment<Empty>", "Environment<Empty>")
        upgraded, writes, _ = run_in_memory(old)
        self.assertEqual(upgraded, current)
        self.assertEqual(set(writes), {TRANSLATE_SCREEN})

    def test_modified_restored_helper_is_rejected_instead_of_duplicated(self):
        first, _, _ = run_in_memory(fixture_files())
        first[TRANSLATE_SCREEN] = first[TRANSLATE_SCREEN].replace(
            'ManagedAnimationItem(source: .local("anim_playpause"),',
            'ManagedAnimationItem(source: .local("different_animation"),',
            1,
        )
        patches = pending_patches(first)
        with self.assertRaisesRegex(ValueError, "translation-sheet-restored-helpers.*expected 1 anchors, found 0"):
            adapt_translation_sheet(patches)

    def test_community_early_return_releases_selection_lock(self):
        patches = pending_patches(fixture_files())
        adapt_community_selection(patches)
        value = patches.pending[CHAT_LIST_CONTROLLER]
        self.assertLess(value.index("openCommunityView"), value.index("clearHighlightAnimated"))
        self.assertLess(value.index("clearHighlightAnimated"), value.index("releasePeerSelection()"))
        self.assertLess(value.index("releasePeerSelection()"), value.index("return"))
        self.assertIn("self.context.sharedContext.navigateToChatController(params)", value)

    def test_passkey_identity_is_captured_before_local_removal_and_used_with_older_sdk(self):
        patches = pending_patches(fixture_files())
        adapt_passkey_credential_identity(patches)
        value = patches.pending[PASSKEYS_SCREEN]
        self.assertLess(value.index("guard let passkey ="), value.index("self.passkeysData?.removeAll"))
        self.assertEqual(value.count("self.passkeysData?.first(where:"), 1)
        before_sdk_guard, guarded_code = value.split("#if compiler(>=6.2)", 1)
        self.assertIn("deletePasskey(id: passkey.id)", before_sdk_guard)
        self.assertIn("if #available(iOS 26.0, *) {", guarded_code)
        self.assertIn("decodeBase64(passkey.id)", guarded_code)
        self.assertIn("reportUnknownPublicKeyCredential", guarded_code)
        self.assertIn("component.passkeysDataUpdated(self.passkeysData ?? [])", value)

    def test_full_apply_writes_once_and_returns_same_report_on_second_pass(self):
        first, writes, report = run_in_memory(fixture_files())
        second, repeated_writes, repeated_report = run_in_memory(first)
        self.assertEqual(set(writes), set(fixture_files()))
        self.assertEqual(first, second)
        self.assertEqual(repeated_writes, {})
        self.assertEqual(report, repeated_report)
        self.assertEqual(report["double-tap-reaction-engine-message"], sorted([BUBBLE, ANIMATED, STICKER]))
        self.assertEqual(report["translation-message-update-transition"], [BUBBLE])
        self.assertEqual(report["translation-sheet-restored-helpers"], [TRANSLATE_SCREEN])

    def test_late_anchor_failure_never_writes_partially_adapted_files(self):
        files = fixture_files()
        files[TRANSLATE_SCREEN] = files[TRANSLATE_SCREEN].replace("replaceText: replaceText)", "replaceText: differentCallback)")
        patches = pending_patches(files)
        with patch("public_api_adaptations.SourcePatches", return_value=patches), patch.object(Path, "write_bytes") as writes:
            with self.assertRaisesRegex(ValueError, "translation-sheet-language-callback"):
                apply_public_api_adaptations(ROOT)
            writes.assert_not_called()

    def test_duplicate_translation_call_is_rejected(self):
        files = fixture_files()
        files[BUBBLE] += TRANSLATION_BUTTON.splitlines()[0] + "\n"
        patches = pending_patches(files)
        with self.assertRaisesRegex(ValueError, "expected 1 anchors, found 2"):
            adapt_translation_button(patches)


ASSEMBLED_SOURCE = os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE")
PUBLIC_SOURCE = os.environ.get("WHITEGRAM_PUBLIC_SOURCE")


@unittest.skipUnless(ASSEMBLED_SOURCE, "set WHITEGRAM_ASSEMBLED_SOURCE for read-only source integration")
class AssembledSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(ASSEMBLED_SOURCE)
        cls.original = {path: (cls.root / path).read_text(encoding="utf-8") for path in fixture_files()}
        cls.adapted, cls.writes, cls.report = run_in_memory(cls.original)

    def upstream(self, relative: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(self.root), "show", f"HEAD:{relative}"],
            stderr=subprocess.PIPE,
        ).decode("utf-8")

    def test_actual_upstream_message_contracts_match_adapted_calls(self):
        predicates = self.upstream(CHAT + "ChatMessageItemCommon/Sources/ChatMessageItemCommon.swift")
        self.assertIn("public func canAddMessageReactions(message: EngineMessage) -> Bool", predicates)
        share = self.upstream(CHAT + "ChatMessageShareButton/Sources/ChatMessageShareButton.swift")
        self.assertIn("message: EngineMessage, accountPeerId: EnginePeer.Id", share)
        interaction = self.upstream("submodules/TelegramUI/Components/ChatControllerInteraction/Sources/ChatControllerInteraction.swift")
        self.assertIn("public let requestMessageUpdate: (EngineMessage.Id, Bool, ControlledTransition?) -> Void", interaction)
        self.assertIn("public let updateMessageReaction: (EngineRawMessage,", interaction)
        self.assertIn("public let openMessageContextMenu: (EngineRawMessage,", interaction)
        aliases = self.upstream("submodules/TelegramCore/Sources/TelegramEngine/Utils/EnginePostboxCoding.swift")
        self.assertIn("public typealias EngineRawMessage = Message", aliases)
        message = self.upstream("submodules/TelegramCore/Sources/TelegramEngine/Messages/Message.swift")
        self.assertIn("public typealias Id = MessageId", message)
        self.assertIn("public init(_ impl: Message)", message)

    def test_actual_assembly_is_idempotent_without_disk_writes(self):
        second, writes, report = run_in_memory(self.adapted)
        self.assertEqual(second, self.adapted)
        self.assertEqual(writes, {})
        self.assertEqual(report, self.report)
        for path in (BUBBLE, ANIMATED, STICKER):
            self.assertNotRegex(self.adapted[path], r"canAddMessageReactions\(message: (?:item|target)\.message\)")
        self.assertNotIn("requestMessageUpdate(item.message.id, false)", self.adapted[BUBBLE])

    def test_translation_helper_dependencies_are_real_upstream_apis(self):
        build = (self.root / "submodules/TranslateUI/BUILD").read_text(encoding="utf-8")
        for dependency in ("//submodules/ManagedAnimationNode", "//submodules/ItemListUI"):
            self.assertIn(dependency, build)
        localizations = self.upstream("submodules/TranslateUI/Sources/LocalizationListItem.swift")
        self.assertIn("id: String, title: String, subtitle: String, checked: Bool, activity: Bool, loading: Bool", localizations)
        controller = self.upstream("submodules/ItemListUI/Sources/ItemListController.swift")
        self.assertIn("public var titleControlValueChanged: ((Int) -> Void)?", controller)
        context = self.upstream("submodules/ContextUI/Sources/ContextController.swift")
        self.assertIn("public init(referenceView: UIView, contentAreaInScreenSpace: CGRect, insets: UIEdgeInsets = UIEdgeInsets()", context)

    def test_passkey_upstream_uses_captured_credential_for_apple_removal(self):
        source = self.upstream(PASSKEYS_SCREEN)
        self.assertLess(source.index("guard let passkey = self.passkeysData?.first(where:"), source.index("self.passkeysData?.removeAll"))
        self.assertIn("decodeBase64(passkey.id)", source)
        auth = self.upstream("submodules/TelegramCore/Sources/TelegramEngine/Auth/TelegramEngineAuth.swift")
        self.assertIn("public func deletePasskey(id: String) -> Signal<Never, NoError>", auth)

    def test_real_tab_bar_options_and_peer_info_callbacks_are_present(self):
        tab_bar = (self.root / "submodules/TelegramUI/Components/TabBarComponent/Sources/TabBarComponent.swift").read_text(encoding="utf-8")
        for name in ("hideItemTitles", "forceFullWidth", "compactPanel", "compactAction"):
            self.assertRegex(tab_bar, rf"public let {name}:")
            self.assertIn(f"self.{name} = {name}", tab_bar)
            self.assertIn(f"component.{name}", tab_bar)
        disclosure = self.upstream("submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/ListItems/PeerInfoScreenDisclosureItem.swift")
        self.assertIn("action: (() -> Void)?", disclosure)
        # The old two-argument menu callback has a genuine convenience overload.
        context = self.upstream("submodules/ContextUI/Sources/ContextController.swift")
        self.assertIn("action: ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?", context)

    def test_adapted_swift_introduces_no_new_tree_sitter_diagnostics(self):
        try:
            from tree_sitter import Language, Parser
            import tree_sitter_swift
        except ImportError:
            self.skipTest("tree-sitter and tree-sitter-swift are required for syntax comparison")

        def errors(parser, text):
            data = text.encode("utf-8")
            nodes = [parser.parse(data).root_node]
            result = collections.Counter()
            while nodes:
                node = nodes.pop()
                if node.type == "ERROR" or node.is_missing:
                    result[(node.type, data[node.start_byte:node.end_byte].decode("utf-8"))] += 1
                else:
                    nodes.extend(node.children)
            return result

        results = []
        failures = []

        def parse_all():
            try:
                parser = Parser(Language(tree_sitter_swift.language()))
                for path, value in self.adapted.items():
                    results.append((path, errors(parser, value) - errors(parser, self.original[path])))
                results.append(("restored translation helpers", errors(parser, TRANSLATION_HELPERS)))
            except Exception as error:
                failures.append(error)

        previous_stack_size = threading.stack_size(64 * 1024 * 1024)
        try:
            worker = threading.Thread(target=parse_all)
            worker.start()
            worker.join()
        finally:
            threading.stack_size(previous_stack_size)
        if failures:
            raise failures[0]
        for path, introduced in results:
            with self.subTest(path=path):
                self.assertEqual(introduced, {})


@unittest.skipUnless(PUBLIC_SOURCE, "set WHITEGRAM_PUBLIC_SOURCE for restored-helper provenance")
class PublicHelperProvenanceTests(unittest.TestCase):
    def test_restored_helpers_match_pinned_public_implementations(self):
        def public_blob(name):
            return subprocess.check_output(
                ["git", "-C", PUBLIC_SOURCE, "show", f"db18308774f863074278feedc4df4507b0fb174e:submodules/TranslateUI/Sources/{name}.swift"],
                stderr=subprocess.PIPE,
            ).decode("utf-8")

        language = public_blob("LanguageSelectionController")
        playback = public_blob("PlayPauseIconComponent")
        screen = public_blob("TranslateScreen")
        context_source = screen[screen.index("private final class GiftViewContextReferenceContentSource:"):]
        expected = "\n".join(line for line in (language + playback + context_source).splitlines() if not line.startswith("import "))
        # The target sheet also imports SwiftUI, whose Environment shadows the
        # ComponentFlow type used by the restored playback component.
        expected = expected.replace("environment: Environment<Empty>", "environment: ComponentFlow.Environment<Empty>")
        # Ignore formatting, but compare string literals independently so a UI
        # label or animation resource cannot change under whitespace normalization.
        strings = r'"(?:\\.|[^"\\])*"'
        self.assertEqual(re.findall(strings, TRANSLATION_HELPERS), re.findall(strings, expected))
        self.assertEqual(re.sub(r"\s+", "", TRANSLATION_HELPERS), re.sub(r"\s+", "", expected))


if __name__ == "__main__":
    unittest.main()
