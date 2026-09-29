# WhiteGram public API adaptation review

## Inputs and integration

- Public WhiteGram 1.0.1: `db18308774f863074278feedc4df4507b0fb174e`, compared with `release-12.6.2` using `git diff -w`. The unfiltered Swift path list contains 140 files; 139 have non-whitespace changes.
- Target: `release-12.9.2`, `6ad963e5b62d354da79040f388ae2b9132fb17b8`.
- The assembled worktree at `C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-port-12.9.2` supplied the post-merge anchors. `git show HEAD:<path>` supplied pristine target API definitions.

Parent integration, after the public merge and compatibility import/dependency pass:

```python
from public_api_adaptations import apply_public_api_adaptations

public_api_features = apply_public_api_adaptations(source_root)
```

The function returns `SourcePatches.write()`'s feature-to-path report: **8 features, 6 target Swift files, 15 required anchor occurrences**. All replacements are validated in memory before that write. A second pass returns the same report with zero writes. Partial, duplicate, or modified required anchors raise `ValueError`.

## Implemented adaptations

Paths below are relative to the assembled source root. `Chat/` abbreviates `submodules/TelegramUI/Components/Chat/`.

| Report feature | Target | Count | Adaptation |
| --- | --- | ---: | --- |
| `double-tap-reaction-engine-message` | `Chat/{ChatMessageBubbleItemNode,ChatMessageAnimatedStickerItemNode,ChatMessageStickerItemNode}/Sources/<node>.swift` | 2 each | Wrap the two new personal/channel reaction predicates in `EngineMessage(...)`. Reaction and context-menu callbacks continue receiving the original raw message. |
| `translation-share-button-signature` | `Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift` | 1 | Pass `EngineMessage(item.message)` and `accountPeerId: item.context.account.peerId` to the translation `ChatMessageShareButton.update` call. |
| `translation-message-update-transition` | Same bubble file | 2 | Supply the required third `nil` transition argument to translation-start and translation-completion `controllerInteraction.requestMessageUpdate` calls. |
| `community-selection-release` | `submodules/ChatListUI/Sources/ChatListController.swift` | 1 | Release WhiteGram's selection lock on the target's new `.community` early-return path, after opening the community and clearing its highlight. Otherwise every later peer selection remains blocked. |
| `passkey-credential-removal-identity` | `submodules/TelegramUI/Components/Settings/PasskeysScreen/Sources/PasskeysScreen.swift` | 2 | Capture the selected passkey before removing it from `passkeysData`; use its id for engine deletion and the Apple credential-store notification. The fork re-looked it up after `removeAll`, making the iOS 26 notification unreachable. Retain the compiler/availability guards, and use the captured value outside the SDK guard as well. |
| `translation-sheet-helper-imports` | `submodules/TranslateUI/Sources/TranslateScreen.swift` | 1 | Import `ItemListUI` and `ManagedAnimationNode`, whose real targets already occur in `TranslateUI/BUILD`. |
| `translation-sheet-restored-helpers` | Same translation screen | 1 | Restore the full language selector, animated play/pause component, and reference context-menu source alongside their consumer. |
| `translation-sheet-language-callback` | Same translation screen | 1 | Forward `translateChat` when language selection reopens the translation sheet, retaining the caller's whole-chat translation action. |

### Message API evidence

The target defines:

```swift
// TelegramCore/Sources/TelegramEngine/Messages/Message.swift
public typealias Id = MessageId                 // nested in EngineMessage
public init(_ impl: Message)

// TelegramCore/Sources/TelegramEngine/Utils/EnginePostboxCoding.swift
public typealias EngineRawMessage = Message

// Chat/ChatMessageItemCommon/Sources/ChatMessageItemCommon.swift
public func canAddMessageReactions(message: EngineMessage) -> Bool

// Chat/ChatMessageShareButton/Sources/ChatMessageShareButton.swift
// Relevant update parameters:
message: EngineMessage, accountPeerId: EnginePeer.Id

// Components/ChatControllerInteraction/Sources/ChatControllerInteraction.swift
public let requestMessageUpdate: (EngineMessage.Id, Bool, ControlledTransition?) -> Void
public let updateMessageReaction: (EngineRawMessage, ChatControllerInteractionReaction, Bool, ContextExtractedContentContainingView?) -> Void
public let openMessageContextMenu: (EngineRawMessage, Bool, ASDisplayNode, CGRect, UIGestureRecognizer?, CGPoint?) -> Void
```

`ChatHistoryListNodeImpl.requestMessageUpdate` is a separate method with defaulted arguments; the one-argument observer calls in `ChatController.swift` are valid. `Message` and `EngineRawMessage` are equivalent, whereas `EngineMessage` is a wrapper. The new Saved Messages helper and double-tap callback therefore retain raw-message semantics. Compatibility imports make the fork's explicit Postbox type spellings available.

Reaction anchors include the fork's `case .reaction` arm. Matching only the wrapped call would incorrectly treat two existing upstream calls in the animated-sticker node as proof that both new calls were already adapted.

### Restored translation dependency evidence

`TranslateScreen.swift` was restored by conflict resolution, but its dependencies were not all part of the public delta:

1. `TranslateUI/Sources/LanguageSelectionController.swift` is unchanged between the fork base and public commit and is absent from target HEAD. The sheet still calls `languageSelectionController(...)`.
2. `TranslateUI/Sources/PlayPauseIconComponent.swift` is likewise unchanged in the public delta and absent from target HEAD. The sheet instantiates `PlayPauseIconComponent` twice.
3. The public `TranslateScreen.swift` ends with the private `GiftViewContextReferenceContentSource` class. It was outside the restored conflict block, so the assembled sheet referenced it without a local declaration. Similarly named classes in GiftViewScreen are private to other files/modules.

The embedded helper implementations match those three pinned public implementations modulo formatting and explicit `ComponentFlow.Environment` qualification. The target sheet imports SwiftUI too, so the playback component cannot use the ambiguous bare `Environment` name. The provenance test compares string literals separately as well as whitespace-normalized source with that qualified type. This retains the original/translation language tabs, completion handling, localized language names, speech animation frames, and context-menu positioning.

The corresponding target definitions were checked: `LocalizationListItem` retains the relevant initializer, `ItemListController` retains its generic state initializer and `titleControlValueChanged`, `ManagedAnimationNode` remains a real dependency, and `ContextControllerReferenceViewInfo` retains its defaulted insets/position arguments. The existing Google/Telegram provider switch, fallback, speech actions, copy/replace actions, and custom resizable sheet are retained.

## Other inspected API boundaries

- **ChatController / LoadDisplayNode:** `setupEditMessage` takes an id and layout callback; pin/unpin take the existing two/three arguments. `beginMediaRecording` still takes one `Bool`. `requestVideoRecorder(initialFrontCamera:)` and the real `VideoMessageCameraScreen` initializer contain the transferred camera parameter. History enumeration and sticker refresh methods exist on the concrete history/display nodes. The thread-data and message-id annotations match existing engine aliases.
- **Message presentation:** the merge already adapts timestamp calls to `context:` plus `EngineMessage`, and inline-reaction predicates to `EngineMessage`. Wide-post/reaction-visibility helpers consume raw messages, matching their bubble/file/media/sticker callers. `premiumEffect` is `TelegramMediaFile.VideoThumbnail?`, compatible with `videoThumbnails.first`. The transition-node protocol exposes `add`/`remove` for the decoration nodes used by immediate animation cleanup.
- **Translation:** `ExperimentalInternalTranslationService.translate` still accepts `[AnyHashable: String]`; `translateMessages` retains `enableLocalIfPossible` and defaults its added tone parameter. `ChatTranslationState` retains the five supplied constructor arguments. The restored sheet's `speakText`, `stringWithAppliedEntities`, and resizable-sheet calls match target declarations.
- **TabBar:** the assembled `TabBarComponent` has actual `hideItemTitles`, `forceFullWidth`, `compactPanel`, and `compactAction` properties, initializer arguments, equality checks, and rendering uses. `TabBarControllerImpl(presentationData:)`, `updatePresentationData`, and `updateLayout` are real public methods. Its parent passes the corresponding settings to the actual component.
- **ChatList / PeerInfo:** `HorizontalTabsComponent.Tab` retains its action/context-action signatures; the latter supplies an optional gesture accepted by `tabContextGesture`. The cached-peer-data resolution uses the target engine API. `PeerInfoScreenDisclosureItem.action` still takes no arguments, and the `.whiteGram` section has a settings dispatcher. `ContextMenuActionItem` retains a real convenience initializer for the two-argument controller/dismiss callback.
- **Settings / network / recording:** ItemList switch/disclosure, custom ListView item, and footer signatures match the added settings UI. The proxy settings' new fields/defaults and three `PresentationCallImpl` construction sites carry the force-TCP setting. The added microphone routing uses existing AVAudioSession operations. Small trailing-comma-only deltas do not justify reverting newer upstream arguments.

## Verification and remaining build validation

**19 tests passed**, with both source integrations enabled:

```powershell
$env:WHITEGRAM_ASSEMBLED_SOURCE = "C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-port-12.9.2"
$env:WHITEGRAM_PUBLIC_SOURCE = "C:\Users\Pisun4ik\AppData\Local\Temp\wg"
& "C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-check-env\Scripts\python.exe" -B -m unittest discover -s "whitegram/tests" -p "test_public_api_adaptations.py" -v
```

Run from `C:\Users\Pisun4ik\AppData\Local\Temp\opencode\telegram-ios-private`. Tests intercept source writes in memory, including `SourcePatches.write()` and the second pass. They cover message-wrapper boundaries, callback arity, helper restoration/provenance, community selection completion, passkey identity, and failure before any writes on a late bad anchor.

Tree-sitter 0.25.2 / tree-sitter-swift 0.7.3 reports **no additional syntax diagnostics** in the six adapted source snapshots; the restored helper block parses without diagnostics. This comparison uses the pre-adaptation assembled files as its baseline, so inherited parser false positives are not claimed as repaired. Python tests and `git diff --no-index --check` also pass for the adaptation/test files.

No additional concrete API/type blocker was identified in the inspected public delta. **Swift/Xcode are unavailable locally**, so a full target Bazel/Xcode build, Apple SDK type checking, dependency-graph validation, and device behavior remain outstanding. These checks do not establish that the app compiles. The parent must invoke the function on its assembled source before that build.
