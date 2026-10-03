import Foundation
import UIKit
import AccountContext
import Display
import SwiftSignalKit
import TelegramCore

private final class WhitegramProfileCoordinator: WhitegramServiceListActions {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    let presenter = WhitegramServicePresenter()
    private let context: AccountContext
    private let targetUserId: Int64
    private let client: WhitegramBackendClient
    private let service: WhitegramProfileService
    private let auth: WhitegramBackendAuthentication
    private var tasks: [WhitegramBackendTask] = []
    private var generation = 0
    private var busy = false
    private var errors: [String: String] = [:]
    private var about: WhitegramProfileAbout?
    private var quote: WhitegramProfileQuote?
    private var lyric: WhitegramProfileLyric?
    private var badge: WhitegramProfileBadge?
    private var scene: WhitegramProfileSceneState?
    private var reactions: WhitegramProfileReactions?
    private var hasSession = false
    private var songs: [WhitegramProfileSong] = []
    private var loaded = Set<WhitegramProfileResource>()

    init(context: AccountContext, userId: Int64) {
        self.context = context
        targetUserId = userId
        client = WhitegramBackendClient(userId: context.account.peerId.id._internalGetInt64Value())
        service = WhitegramProfileService(client: client)
        auth = WhitegramBackendAuthentication(context: context, client: client)
        refresh()
    }
    deinit { tasks.forEach { $0.cancel() } }
    private var isOwnProfile: Bool { return targetUserId == client.userId }
    func setEnabled(_ enabled: Bool) {}

    func load() {
        guard !busy else { return }
        generation += 1
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        loaded.removeAll()
        about = nil; quote = nil; lyric = nil; badge = nil; scene = nil; reactions = nil
        errors.removeAll()
        do { hasSession = try client.hasSession() }
        catch { errors["session"] = error.localizedDescription; hasSession = false }
        guard hasSession else { refresh(); return }
        fetch(WhitegramProfileAbout.self, .about) { [weak self] in self?.about = $0 }
        fetch(WhitegramProfileQuoteEnvelope.self, .quote) { [weak self] in self?.quote = $0.quote }
        fetch(WhitegramProfileLyricEnvelope.self, .lyric) { [weak self] in self?.lyric = $0.lyric }
        fetch(WhitegramProfileBadge.self, .badge) { [weak self] in self?.badge = $0 }
        fetch(WhitegramProfileSceneState.self, .scene) { [weak self] in self?.scene = $0 }
        fetch(WhitegramProfileReactions.self, .reactions) { [weak self] in self?.reactions = $0 }
        refresh()
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ resource: WhitegramProfileResource, apply: @escaping (T) -> Void) {
        let generation = self.generation
        tasks.append(service.fetch(type, resource: resource, userId: targetUserId, force: true) { [weak self] result in
            guard let self, generation == self.generation else { return }
            switch result {
            case let .success(value): loaded.insert(resource); apply(value)
            case let .failure(error): errors[resource.rawValue] = error.localizedDescription
            }
            refresh()
        })
    }

    private func completed(_ result: Result<Void, WhitegramBackendError>) {
        busy = false
        switch result {
        case .success: load()
        case let .failure(error): errors["save"] = error.localizedDescription; refresh()
        }
    }

    private func save<T: Encodable>(_ value: T, path: String) {
        guard isOwnProfile, !busy else { return }
        busy = true
        errors.removeValue(forKey: "save")
        refresh()
        tasks.append(service.save(value, path: path) { [weak self] in self?.completed($0) })
    }

    private func editor(title: String, text: String, limit: Int, completion: @escaping (String) -> Void) {
        let editor = WhitegramProfileTextEditor(title: title, text: text, maximumLength: limit,
            message: "Save publishes to your Whitegram profile. Editing this text replaces its rich-text formatting.",
            saved: { [weak self] value in self?.presenter.close(); completion(value) }, cancelled: { [weak self] in self?.presenter.close() })
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .formSheet
        if !presenter.present(navigation) { errors["screen"] = "Wait for the screen transition to finish."; refresh() }
    }

    private func choose(title: String, options: [(String, () -> Void)]) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (title, action) in options {
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in self?.presenter.close(); action() })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.presenter.close() })
        alert.popoverPresentationController?.sourceView = presenter.controller?.view
        alert.popoverPresentationController?.sourceRect = CGRect(x: 30, y: 100, width: 1, height: 1)
        if !presenter.present(alert) { errors["screen"] = "Wait for the screen transition to finish."; refresh() }
    }

    func perform(_ id: String) {
        if id == "connect" {
            guard !busy else { return }
            busy = true; refresh()
            auth.connect { [weak self] in self?.completed($0) }
            return
        }
        if id == "reload" { load(); return }
        if id == "access" {
            guard !busy else { return }
            busy = true; refresh()
            tasks.append(client.refreshAccess { [weak self] result in
                self?.completed(result.flatMap { $0 == .allowed ? .success(Void()) : .failure(.betaAccessDenied) })
            })
            return
        }
        if id == "wall" {
            presenter.controller?.navigationController?.pushViewController(whitegramProfileWallController(context: context, userId: targetUserId), animated: true)
            return
        }
        if id == "photos" {
            presenter.controller?.navigationController?.pushViewController(whitegramProfilePhotosController(context: context, userId: targetUserId), animated: true)
            return
        }
        if id == "streaks" {
            presenter.controller?.navigationController?.pushViewController(whitegramProfileStreakController(context: context), animated: true)
            return
        }
        if id == "registration" {
            presenter.controller?.navigationController?.pushViewController(whitegramProfileRegistrationController(context: context, userId: targetUserId), animated: true)
            return
        }
        if id.hasPrefix("vote."), hasSession, !isOwnProfile, !busy, reactions?.enabled == true {
            let emoji = String(id.dropFirst(5))
            guard reactions?.emojis.contains(emoji) == true else { return }
            busy = true; refresh()
            do {
                tasks.append(try service.vote(userId: targetUserId, emoji: emoji) { [weak self] result in
                    guard let self else { return }
                    busy = false
                    switch result {
                    case let .success(value): reactions = value; errors.removeValue(forKey: "vote")
                    case let .failure(error): errors["vote"] = error.localizedDescription
                    }
                    refresh()
                })
            } catch { busy = false; errors["vote"] = error.localizedDescription; refresh() }
            return
        }
        guard hasSession, isOwnProfile, !busy else { return }
        let required: WhitegramProfileResource?
        switch id {
        case "about", "aboutEnabled": required = .about
        case "quote", "quoteEnabled": required = .quote
        case "lyric", "lyricEnabled", "lyricAnimation": required = .lyric
        case "badge": required = .badge
        case "scene": required = .scene
        case "reactions", "reactionEmojis": required = .reactions
        default: required = nil
        }
        if let required, !loaded.contains(required) { return }
        switch id {
        case "about":
            editor(title: "Whitegram About", text: about?.text ?? "", limit: 1200) { [weak self] text in
                guard let self else { return }
                save(WhitegramProfileAbout(enabled: true, text: text, entities: text == about?.text ? (about?.entities ?? []) : [], image: about?.image), path: "/v1/profile/about")
            }
        case "quote":
            editor(title: "Profile Quote", text: quote?.text ?? "", limit: 1200) { [weak self] text in
                guard let self else { return }
                save(WhitegramProfileQuoteEnvelope(quote: WhitegramProfileQuote(enabled: true, text: text,
                    entities: text == quote?.text ? (quote?.entities ?? []) : [], updatedAt: nil)), path: "/v1/profile/quote")
            }
        case "quoteEnabled":
            guard var value = quote else { return }
            value.enabled.toggle()
            save(WhitegramProfileQuoteEnvelope(quote: value), path: "/v1/profile/quote")
        case "aboutEnabled":
            guard var value = about else { return }
            value.enabled.toggle()
            save(value, path: "/v1/profile/about")
        case "badge": save(WhitegramProfileRequests.Enabled(enabled: !(badge?.enabled ?? false)), path: "/v1/profile/badge")
        case "scene":
            choose(title: "Profile Scene", options: WhitegramProfileScene.allCases.map { scene in
                (scene.rawValue.capitalized, { [weak self] in self?.save(WhitegramProfileSceneState(scene: scene), path: "/v1/profile/scene") })
            })
        case "lyricEnabled":
            guard var value = lyric else { return }
            value.enabled.toggle()
            save(WhitegramProfileLyricEnvelope(lyric: value), path: "/v1/profile/lyric")
        case "lyricAnimation":
            guard let lyric else { return }
            let labels = ["None", "Typing", "Scramble", "Fade and slide", "Soft glow"]
            choose(title: "Lyric Animation", options: WhitegramProfileLyricAnimation.allCases.map { animation in
                (labels[animation.rawValue], { [weak self] in var value = lyric; value.animation = animation; self?.save(WhitegramProfileLyricEnvelope(lyric: value), path: "/v1/profile/lyric") })
            })
        case "lyric": searchLyrics()
        case "reactions":
            let value = WhitegramProfileRequests.Reactions(enabled: !(reactions?.enabled ?? false), emojis: reactions?.emojis ?? [])
            save(value, path: "/v1/profile-reactions/config")
        case "reactionEmojis":
            editor(title: "Profile Reactions", text: reactions?.emojis.joined(separator: " ") ?? "", limit: 100) { [weak self] text in
                let emojis = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard let self else { return }
                guard !emojis.isEmpty, Set(emojis).count == emojis.count, emojis.allSatisfy({ $0.utf8.count <= 128 }) else {
                    errors["reactions"] = "Choose distinct, nonempty reaction emoji."; refresh(); return
                }
                save(WhitegramProfileRequests.Reactions(enabled: true, emojis: emojis), path: "/v1/profile-reactions/config")
            }
        default: break
        }
    }

    private func searchLyrics() {
        editor(title: "Search songs", text: "", limit: 200) { [weak self] query in
            guard let self else { return }
            busy = true; refresh()
            tasks.append(service.searchSongs(query) { [weak self] result in
                guard let self else { return }
                busy = false
                switch result {
                case let .failure(error): errors["lyrics"] = error.localizedDescription
                case let .success(songs):
                    self.songs = songs
                    choose(title: "Songs", options: songs.prefix(30).map { song in (song.artist + " — " + song.title, { [weak self] in self?.selectSong(song) }) })
                }
                refresh()
            })
        }
    }

    private func selectSong(_ song: WhitegramProfileSong) {
        busy = true; refresh()
        tasks.append(service.lyrics(song: song) { [weak self] result in
            guard let self else { return }
            busy = false
            switch result {
            case let .failure(error): errors["lyrics"] = error.localizedDescription
            case let .success(text):
                let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                choose(title: "Choose the first of up to four lines", options: lines.enumerated().prefix(150).map { index, line in
                    (line, { [weak self] in
                        guard let self else { return }
                        let selected = Array(lines.dropFirst(index).prefix(4))
                        editor(title: "Selected lyric (up to four lines)", text: selected.joined(separator: "\n"), limit: 1200) { [weak self] text in
                            guard let self else { return }
                            let parts = text.components(separatedBy: .newlines)
                            guard parts.count <= 4 else { errors["lyrics"] = "Select at most four lines."; refresh(); return }
                            let padded = parts + Array(repeating: "", count: 4 - parts.count)
                            let value = WhitegramProfileLyric(enabled: true, songTitle: song.title, artist: song.artist, songUrl: song.url,
                                line1: padded[0], line2: padded[1], line3: padded[2], line4: padded[3], animation: lyric?.animation ?? .none, updatedAt: nil)
                            save(WhitegramProfileLyricEnvelope(lyric: value), path: "/v1/profile/lyric")
                        }
                    })
                })
            }
            refresh()
        })
    }

    private func refresh() {
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ content: WhitegramServiceEntry.Content, section: Int32 = 0) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: section, content: content))
        }
        let editable = hasSession && isOwnProfile && !busy
        func canEdit(_ resource: WhitegramProfileResource) -> Bool { return editable && loaded.contains(resource) }
        add("identity", .text("Whitegram profile: \(targetUserId)"))
        if WhitegramPreferences.bool("scammerProtection") {
            switch whitegramScammerAssessment(userId: targetUserId) {
            case let .listed(savedAt):
                add("scammerWarning", .text(WhitegramLocalization.string("profile.scammerWarningLabel") + "\n" + WhitegramLocalization.string("profile.scammerWarningText")))
                if let savedAt { add("scammerCacheDate", .text("Saved list: " + whitegramServiceDate(savedAt))) }
            case .invalidCache: add("scammerCacheError", .text("The saved Whitegram scammer list could not be read."))
            case .unavailable: add("scammerCacheMissing", .text("No saved Whitegram scammer list is available."))
            case .notListed: break
            }
        }
        add("connect", .action(busy ? "Working…" : "Connect this account to Whitegram", !busy))
        let access = client.access.state(userId: client.userId, now: Date())
        add("access", .disclosure("Beta access", access == .allowed ? "Allowed" : (access == .denied ? "Denied" : "Not verified"), !busy))
        add("authInfo", .text("Uses the original Whitegram API and its Telegram authentication mini app. Profile changes are published only after you save."))
        add("reload", .action("Refresh profile", !busy))
        add("about", .disclosure("About", about?.text ?? "Not loaded", canEdit(.about)), section: 1)
        if let about { add("aboutEnabled", .disclosure("Show About", about.enabled ? "On" : "Off", editable), section: 1) }
        add("quote", .disclosure("Quote", quote?.text ?? "No quote loaded", canEdit(.quote)), section: 1)
        if let quote { add("quoteEnabled", .disclosure("Show quote", quote.enabled ? "On" : "Off", editable), section: 1) }
        add("lyric", .disclosure("Song lyrics", lyric?.lines.joined(separator: " / ") ?? "No lyric loaded", canEdit(.lyric)), section: 2)
        if let lyric {
            add("lyricEnabled", .disclosure("Show lyric", lyric.enabled ? "On" : "Off", editable), section: 2)
            add("lyricAnimation", .disclosure("Lyric animation", String(lyric.animation.rawValue), editable), section: 2)
        }
        add("badge", .disclosure("Whitegram badge", badge.map { $0.enabled ? "On" : "Off" } ?? "Not loaded", editable && badge != nil), section: 3)
        if let badge {
            for (index, text) in [badge.badgeText, badge.verificationText, badge.role].compactMap({ $0 }).enumerated() { add("badge.\(index)", .text(text), section: 3) }
            if let presence = badge.presence, presence.isCurrent(at: Date()) { add("presence", .text(presence.text ?? presence.kind), section: 3) }
        }
        add("scene", .disclosure("Profile scene", scene?.scene.rawValue ?? "Not loaded", canEdit(.scene)), section: 3)
        add("reactions", .disclosure("Profile reactions", reactions.map { $0.enabled ? "On" : "Off" } ?? "Not loaded", editable && reactions != nil), section: 4)
        add("reactionEmojis", .disclosure("Reaction emoji", reactions?.emojis.joined(separator: " ") ?? "Not loaded", editable && reactions != nil), section: 4)
        if let reactions {
            for emoji in reactions.emojis {
                let label = "\(emoji): \(reactions.counts[emoji] ?? 0)" + (reactions.myVotes[emoji] == true ? " · Selected" : "")
                add("vote.\(emoji)", .action(label, hasSession && !isOwnProfile && !busy && reactions.enabled), section: 4)
            }
        }
        add("wall", .action("Open profile wall", hasSession), section: 5)
        add("photos", .action("Profile photos and photo wall", hasSession), section: 5)
        add("streaks", .action(WhitegramLocalization.string("s.whitegramStreak"), true), section: 5)
        if WhitegramPreferences.bool("showRegistrationDateCard") || isOwnProfile { add("registration", .action("Registration date", hasSession), section: 5) }
        for (key, text) in errors.sorted(by: { $0.key < $1.key }) { add("error." + key, .text(key.capitalized + ": " + text), section: 6) }
        entries.set(rows)
    }
}

public func whitegramProfileController(context: AccountContext, userId: Int64? = nil) -> ViewController {
    let coordinator = WhitegramProfileCoordinator(context: context, userId: userId ?? context.account.peerId.id._internalGetInt64Value())
    let controller = whitegramServiceListController(context: context, title: "Whitegram Profile", entries: coordinator.entries.get(), actions: coordinator)
    coordinator.presenter.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.load() }
    return controller
}
