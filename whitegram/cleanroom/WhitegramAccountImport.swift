import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

public protocol WhitegramAccountSessionHost: AnyObject {
    var whitegramOpenSessionAccount: (AccountRecordId, AccountBackupData?, Bool) -> Signal<AccountResult, NoError> { get }
}

public enum WhitegramAccountLogin {
    case session(WhitegramSessionBackup)
    case bot(token: String, testingEnvironment: Bool)

    var identity: WhitegramSessionIdentity {
        get throws {
            switch self {
            case let .session(backup): return backup.account.identity
            case let .bot(token, testing): return WhitegramSessionIdentity(userId: try WhitegramAccountSelection.botUserId(token: token.trimmingCharacters(in: .whitespacesAndNewlines)), testingEnvironment: testing)
            }
        }
    }
}

extension WhitegramSessionBackup {
    public var telegramBackup: AccountBackupData {
        return AccountBackupData(masterDatacenterId: account.dcId, peerId: account.identity.peerId, masterDatacenterKey: account.authKey, masterDatacenterKeyId: WhitegramSessionCrypto.authKeyId(account.authKey), notificationEncryptionKeyId: notificationEncryptionKeyId, notificationEncryptionKey: notificationEncryptionKey, additionalDatacenterKeys: additionalDatacenterKeys.mapValues { AccountBackupData.DatacenterKey(id: $0.id, keyId: $0.keyId, key: $0.key) })
    }
}

public func whitegramSnapshotSession(account: Account) -> Signal<WhitegramSessionBackup, WhitegramSessionError> {
    return combineLatest(accountBackupData(postbox: account.postbox), account.postbox.transaction { $0.getPeer(account.peerId) as? TelegramUser })
    |> castError(WhitegramSessionError.self)
    |> mapToSignal { backup, user -> Signal<WhitegramSessionBackup, WhitegramSessionError> in
        guard let backup, let user, backup.peerId == account.peerId.toInt64() else { return .fail(.missingIdentity) }
        do {
            let portable = try WhitegramPortableAccount(dcId: backup.masterDatacenterId, authKey: backup.masterDatacenterKey, userId: account.peerId.id._internalGetInt64Value(), name: [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " "), phone: user.phone, testingEnvironment: account.testingEnvironment)
            guard backup.masterDatacenterKeyId == WhitegramSessionCrypto.authKeyId(portable.authKey) else { return .fail(.invalidKey) }
            let result = try WhitegramSessionBackup(account: portable, recordId: account.id.int64, additionalDatacenterKeys: backup.additionalDatacenterKeys.mapValues { WhitegramSessionBackup.DatacenterKey(id: $0.id, keyId: $0.keyId, key: $0.key) }, notificationEncryptionKeyId: backup.notificationEncryptionKeyId, notificationEncryptionKey: backup.notificationEncryptionKey)
            return .single(result)
        } catch { return .fail(error as? WhitegramSessionError ?? .invalidFormat) }
    }
}

private struct WhitegramVerifiedAccount {
    let id: AccountRecordId
    let postbox: Postbox
    let apiUser: Api.User
    let masterDatacenterId: Int32
    let appVersion: String
    let keepAlive: AnyObject
}

public func whitegramImportAccount(host: WhitegramAccountSessionHost, accountManager: AccountManager<TelegramAccountManagerTypes>, login: WhitegramAccountLogin, existingIdentities: Set<WhitegramSessionIdentity>) -> Signal<AccountRecordId, WhitegramSessionError> {
    let identity: WhitegramSessionIdentity
    do { identity = try login.identity }
    catch { return .fail(error as? WhitegramSessionError ?? .invalidFormat) }
    guard !existingIdentities.contains(identity) else { return .fail(.duplicateIdentity) }
    return Signal { subscriber in
        let state = WhitegramAccountImportState()
        let operation = accountManager.transaction { transaction -> Int64? in
            return state.allocate {
                let id = generateAccountRecordId()
                transaction.updateRecord(id, { _ in AccountRecord(id: id, attributes: [], temporarySessionId: accountManager.temporarySessionId) })
                return id.int64
            }
        }
        |> castError(WhitegramSessionError.self)
        |> mapToSignal { rawId -> Signal<WhitegramVerifiedAccount, WhitegramSessionError> in
            guard let rawId else { return .fail(.cancelled) }
            let id = AccountRecordId(rawValue: rawId)
            let backup: AccountBackupData?
            if case let .session(session) = login { backup = session.telegramBackup } else { backup = nil }
            return host.whitegramOpenSessionAccount(id, backup, identity.testingEnvironment)
            |> filter { result in if case .upgrading = result { return false }; return true }
            |> take(1)
            |> castError(WhitegramSessionError.self)
            |> timeout(30.0, queue: .concurrentDefaultQueue(), alternate: .fail(.timeout))
            |> mapToSignal { result in
                switch (login, result) {
                case let (.session(_), .authorized(account)):
                    account.shouldBeServiceTaskMaster.set(.single(.always))
                    return account.network.request(Api.functions.users.getUsers(id: [.inputUserSelf]), automaticFloodWait: false)
                    |> mapError { WhitegramSessionError.authorization($0.errorDescription) }
                    |> timeout(30.0, queue: .concurrentDefaultQueue(), alternate: .fail(.timeout))
                    |> mapToSignal { users -> Signal<WhitegramVerifiedAccount, WhitegramSessionError> in
                        guard users.count == 1, whitegramMatchesUser(users[0], identity: identity, requiresBot: false) else { return .fail(.identityMismatch) }
                        return .single(WhitegramVerifiedAccount(id: id, postbox: account.postbox, apiUser: users[0], masterDatacenterId: Int32(account.network.datacenterId), appVersion: account.networkArguments.appVersion, keepAlive: account))
                    }
                    |> afterDisposed { account.shouldBeServiceTaskMaster.set(.single(.never)) }
                case let (.bot(token, _), .unauthorized(account)):
                    return whitegramAuthorizeBot(accountManager: accountManager, account: account, token: token.trimmingCharacters(in: .whitespacesAndNewlines), identity: identity, visitedDatacenters: [])
                default: return .fail(.invalidFormat)
                }
            }
        }
        |> mapToSignal { verified -> Signal<AccountRecordId, WhitegramSessionError> in
            return verified.postbox.transaction { transaction -> Void in
                let peerId = PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(identity.userId))
                updatePeers(transaction: transaction, accountPeerId: peerId, peers: AccumulatedPeers(users: [verified.apiUser]))
                initializedAppSettingsAfterLogin(transaction: transaction, appVersion: verified.appVersion, syncContacts: false)
                if case let .session(session) = login, let secret = session.notificationEncryptionKey {
                    transaction.setKeychainEntry(secret, forKey: "master-notification-secret")
                }
                transaction.setState(AuthorizedAccountState(isTestingEnvironment: identity.testingEnvironment, masterDatacenterId: verified.masterDatacenterId, peerId: peerId, state: nil, invalidatedChannels: []))
            }
            |> castError(WhitegramSessionError.self)
            |> mapToSignal { _ in
                return accountBackupData(postbox: verified.postbox)
                |> castError(WhitegramSessionError.self)
                |> mapToSignal { backup -> Signal<AccountRecordId, WhitegramSessionError> in
                    guard let backup, backup.peerId == identity.peerId, backup.masterDatacenterId == verified.masterDatacenterId,
                          backup.masterDatacenterKey.count == 256, backup.masterDatacenterKeyId == WhitegramSessionCrypto.authKeyId(backup.masterDatacenterKey) else { return .fail(.invalidKey) }
                    return accountManager.transaction { transaction -> Bool in
                        // Keep the staged network/postbox alive until the record transaction completes.
                        withExtendedLifetime(verified.keepAlive) {
                            return state.commit {
                                guard let record = transaction.getRecords().first(where: { $0.id == verified.id }), record.temporarySessionId == accountManager.temporarySessionId else { return false }
                                guard !transaction.getRecords().contains(where: { $0.id != verified.id && whitegramRecordIdentity($0) == identity }) else { return false }
                                let maximumOrder = transaction.getRecords().flatMap { $0.attributes }.compactMap { attribute -> Int32? in
                                    if case let .sortOrder(order) = attribute { return order.order }; return nil
                                }.max() ?? 0
                                let attributes: [TelegramAccountRecordAttribute] = [.environment(AccountEnvironmentAttribute(environment: identity.testingEnvironment ? .test : .production)), .sortOrder(AccountSortOrderAttribute(order: maximumOrder == Int32.max ? maximumOrder : maximumOrder + 1)), .backupData(AccountBackupDataAttribute(data: backup))]
                                transaction.updateRecord(verified.id, { _ in AccountRecord(id: verified.id, attributes: attributes, temporarySessionId: nil) })
                                return true
                            }
                        }
                    }
                    |> castError(WhitegramSessionError.self)
                    |> mapToSignal { committed in committed ? .single(verified.id) : .fail(.duplicateIdentity) }
                }
            }
        }
        |> `catch` { error -> Signal<AccountRecordId, WhitegramSessionError> in
            return whitegramRollbackAccount(state: state, manager: accountManager)
            |> castError(WhitegramSessionError.self)
            |> mapToSignal { _ in .fail(error) }
        }
        let disposable = operation.start(next: subscriber.putNext, error: subscriber.putError, completed: subscriber.putCompletion)
        return ActionDisposable {
            disposable.dispose()
            let _ = whitegramRollbackAccount(state: state, manager: accountManager).start()
        }
    }
}

private func whitegramRollbackAccount(state: WhitegramAccountImportState, manager: AccountManager<TelegramAccountManagerTypes>) -> Signal<Void, NoError> {
    let id = state.cancel()
    return manager.transaction { transaction -> Void in
        guard let id else { return }
        let recordId = AccountRecordId(rawValue: id)
        transaction.updateRecord(recordId, { record in
            guard let record, record.temporarySessionId == manager.temporarySessionId else { return record }
            return nil
        })
    }
}

public func whitegramRecordIdentity(_ record: AccountRecord<TelegramAccountRecordAttribute>) -> WhitegramSessionIdentity? {
    var testing = false
    var peerId: Int64?
    for attribute in record.attributes {
        if case let .environment(value) = attribute { testing = value.environment == .test }
        if case let .backupData(value) = attribute { peerId = value.data?.peerId }
    }
    guard let peerId else { return nil }
    return try? WhitegramSessionIdentity.fromPeerId(peerId, testingEnvironment: testing)
}

private func whitegramMatchesUser(_ user: Api.User, identity: WhitegramSessionIdentity, requiresBot: Bool) -> Bool {
    guard case let .user(data) = user, data.id == identity.userId, data.flags & (1 << 13) == 0 else { return false }
    return !requiresBot || data.flags & (1 << 14) != 0
}

private func whitegramAuthorizeBot(accountManager: AccountManager<TelegramAccountManagerTypes>, account: UnauthorizedAccount, token: String, identity: WhitegramSessionIdentity, visitedDatacenters: Set<Int32>) -> Signal<WhitegramVerifiedAccount, WhitegramSessionError> {
    var visitedDatacenters = visitedDatacenters
    guard visitedDatacenters.insert(account.masterDatacenterId).inserted, visitedDatacenters.count <= 3 else { return .fail(.invalidDatacenter) }
    let request = Api.functions.auth.importBotAuthorization(flags: 0, apiId: account.networkArguments.apiId, apiHash: account.networkArguments.apiHash, botAuthToken: token)
    let redacted = Api.functions.auth.importBotAuthorization(flags: 0, apiId: account.networkArguments.apiId, apiHash: "[redacted]", botAuthToken: "[redacted]")
    account.shouldBeServiceTaskMaster.set(.single(.always))
    return account.network.request((redacted.0, request.1, request.2), automaticFloodWait: false)
    |> mapToSignal { authorization -> Signal<WhitegramVerifiedAccount, MTRpcError> in
        guard case let .authorization(data) = authorization, whitegramMatchesUser(data.user, identity: identity, requiresBot: true) else { return .fail(MTRpcError(errorCode: 400, errorDescription: "BOT_TOKEN_INVALID")) }
        return .single(WhitegramVerifiedAccount(id: account.id, postbox: account.postbox, apiUser: data.user, masterDatacenterId: account.masterDatacenterId, appVersion: account.networkArguments.appVersion, keepAlive: account))
    }
    |> `catch` { error -> Signal<WhitegramVerifiedAccount, WhitegramSessionError> in
        let description = error.errorDescription
        for prefix in ["USER_MIGRATE_", "PHONE_MIGRATE_", "NETWORK_MIGRATE_"] {
            if description.hasPrefix(prefix), let dc = Int32(description.dropFirst(prefix.count)), (1...5).contains(dc), !identity.testingEnvironment || dc <= 3 {
                return account.changedMasterDatacenterId(accountManager: accountManager, masterDatacenterId: dc)
                |> castError(WhitegramSessionError.self)
                |> mapToSignal { updated in whitegramAuthorizeBot(accountManager: accountManager, account: updated, token: token, identity: identity, visitedDatacenters: visitedDatacenters) }
            }
        }
        return .fail(WhitegramSessionError.authorization(description))
    }
    |> timeout(45.0, queue: .concurrentDefaultQueue(), alternate: .fail(.timeout))
    |> afterDisposed { account.shouldBeServiceTaskMaster.set(.single(.never)) }
}

public func whitegramHandleUnavailableAccount(account: Account, accountManager: AccountManager<TelegramAccountManagerTypes>, alreadyLoggedOutRemotely: Bool = false) -> Signal<Void, NoError> {
    guard WhitegramPreferences.bool("keepUnavailableAccounts") else { return logoutFromAccount(id: account.id, accountManager: accountManager, alreadyLoggedOutRemotely: alreadyLoggedOutRemotely) }
    WhitegramAccountFrozenStore.shared.markFrozen(accountId: account.id.int64, peerId: account.peerId.toInt64(), reason: .sessionRevoked)
    account.shouldBeServiceTaskMaster.set(.single(.never))
    return .single(Void())
}

func whitegramRecordAuthorizationFailure(accountManager: AccountManager<TelegramAccountManagerTypes>, accountId: AccountRecordId, peerId: PeerId, description: String) {
    guard WhitegramPreferences.bool("keepUnavailableAccounts"), let reason = WhitegramAccountUnavailableReason.rpcError(description) else { return }
    let _ = accountManager.transaction { transaction -> Void in
        guard let record = transaction.getRecords().first(where: { $0.id == accountId }), record.temporarySessionId == nil else { return }
        WhitegramAccountFrozenStore.shared.markFrozen(accountId: accountId.int64, peerId: peerId.toInt64(), reason: reason)
    }.start()
}

public func whitegramRecheckRetainedAccount(account: Account) -> Signal<Void, WhitegramSessionError> {
    let identity = WhitegramSessionIdentity(userId: account.peerId.id._internalGetInt64Value(), testingEnvironment: account.testingEnvironment)
    return account.shouldBeServiceTaskMaster.get()
    |> take(1)
    |> castError(WhitegramSessionError.self)
    |> mapToSignal { previous in
        account.shouldBeServiceTaskMaster.set(.single(.always))
        return account.network.request(Api.functions.users.getUsers(id: [.inputUserSelf]), automaticFloodWait: false)
        |> mapError { WhitegramSessionError.authorization($0.errorDescription) }
        |> timeout(30.0, queue: .concurrentDefaultQueue(), alternate: .fail(.timeout))
        |> mapToSignal { users -> Signal<Void, WhitegramSessionError> in
            guard users.count == 1, whitegramMatchesUser(users[0], identity: identity, requiresBot: false) else { return .fail(.identityMismatch) }
            guard WhitegramAccountFrozenStore.shared.clear(accountId: account.id.int64) else { return .fail(.storageVerification) }
            return .single(Void())
        }
        |> afterDisposed { account.shouldBeServiceTaskMaster.set(.single(previous)) }
    }
}
