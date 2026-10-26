import CryptoKit
import Foundation
import GRDB
import os

/// How the household key reaches the member's device (step 7a Task 8): a key exchange the admin confirms by comparing
/// a 6-digit code that both screens show, side by side.
///
/// Where the records go: the household share is read-only for her (Task 7), so she can't write in `household`. Her
/// device's request goes on the container's **public database** (`SyncPublicBoard`): the server says who wrote it, only
/// she can change or delete it, and the Mac fetches it by name (no query, no index, no second share to accept). Its name
/// is a hash of the household share's identity and her iCloud user (`requestName`), so it names neither, and someone who
/// doesn't know the share can't take the name first. Nothing secret goes there. The Mac's answers go in `household`,
/// which she reads: its ephemeral public key (`keyOffer-<request id>`) and the sealed grant (`keyGrant-<request id>`,
/// exactly `sealed` and `keyId`). Every engine passes over these records (`SyncEngineCore.reservedRecordTypes`).
///
/// The protocol (a commit-then-reveal short authentication string, as in ZRTP or Bluetooth numeric comparison,
/// built only from CryptoKit's SHA-256, X25519, HKDF-SHA256 and AES-GCM):
/// 1. Her device makes a Curve25519 key pair B and a 32-byte nonce, kept in memory only, and posts a request id and a
///    commitment `SHA-256(request id, B, nonce)`.
/// 2. The Mac, seeing a fresh request written by her iCloud user while she is an accepted participant, keeps the
///    commitment and answers with an ephemeral Curve25519 public key A of its own (`keyOffer`), its private half in
///    memory only.
/// 3. Her device checks that its request is still the one on the board, then reveals B and its nonce. The Mac checks
///    them against the commitment it kept.
/// 4. Both compute the code from a transcript hash over the household zone, the owner's and her record names, the
///    request id, B, her nonce and A, and show it. Because each side fixed its contribution before seeing the other's,
///    a server that swaps a key can match the two codes only by chance (one in a million).
/// 5. Only when the admin confirms the code ("Give the key") does the Mac seal every household key to B. The box key is
///    HKDF-SHA256 over two X25519 agreements, the Mac's key A with B (so only the Mac that answered can make a grant
///    that opens: the server, which knows every public value, can't) and a fresh ephemeral key with B; salt: the
///    request id; info: `info`, "/grant" and the transcript. AES-GCM authenticates the grant's name, A, the ephemeral
///    key, B and the transcript. Saved create-only, so once per request.
/// 6. Her device opens the grant only with B's private key and the A of the offer its code used, stores the keys, and
///    deletes its request; the Mac then deletes its offer and the grant.
///
/// A request expires `lifetime` after the Mac first answers it (or is ignored when already that old), and her device
/// gives up after the same time. A request that is declined, refused, expired or granted is never answered again, also
/// after the Mac relaunches (`Ledger`, in `syncState`). After `maxFailedAttempts` declined or refused codes in a row
/// the Mac answers no request of hers for `lockout`. A member no longer on the share is refused, before the answer and
/// again at the grant.
public enum SyncKeyExchange {
    public static let requestRecordType = "keyRequest"
    public static let offerRecordType = "keyOffer"
    public static let grantRecordType = "keyGrant"
    /// The domain of every hash and of the grant's key derivation.
    public static let info = "mango-household-key-v1"
    /// The grant's `keyId`: the exchange's format, not a zone key.
    public static let keyId = "exchange-v1"
    /// How long a request stays open.
    public static let lifetime: TimeInterval = 10 * 60
    /// Declined or refused codes in a row before the Mac stops answering her requests for `lockout`.
    public static let maxFailedAttempts = 3
    public static let lockout: TimeInterval = 15 * 60
    /// Only declined or refused codes within this long of each other count towards the lockout.
    public static let failureWindow: TimeInterval = 60 * 60
    /// CloudKit's zone-wide share record name (`CKRecordNameZoneWideShare`): part of the share's identity in
    /// `requestName`.
    public static let zoneShareRecordName = "cloudkit.zoneshare"
    static let recordTypes: Set<String> = [requestRecordType, offerRecordType, grantRecordType]

    static let requestIdField = "requestId"
    static let commitmentField = "commitment"
    static let publicKeyField = "publicKey"
    static let nonceField = "nonce"
    static let sealedField = FieldSealing.sealedField
    static let keyIdField = FieldSealing.keyIdField
    /// At most this many household keys travel in one grant.
    static let maxKeys = 256

    private static let log = Logger(subsystem: "com.personal.budget", category: "Sync")

    public enum ExchangeError: Error, Equatable, Sendable {
        /// The request is older than `lifetime`.
        case expired
        /// The requester isn't an accepted participant of the household share (never invited, or removed).
        case notAMember
        /// Not the request this Mac answered, or it was granted, declined or refused already.
        case notConfirmable
        /// This Mac holds no household key to give.
        case noKeys
        /// More household keys than one grant carries (`maxKeys`).
        case tooManyKeys
        /// A grant that doesn't open, or isn't the shape it must be.
        case unreadableGrant
    }

    /// The member's request as the Mac shows it, once her device has revealed its key: confirm `code` with her.
    public struct Request: Equatable, Sendable {
        public let id: String
        public let code: String
        /// Who the server says wrote the request.
        public let lastModifiedBy: String
        let publicKey: Data
        let transcript: Data
    }

    /// Her request's name on the public database: a hash of the household share's identity (zone, owner, share record)
    /// and her iCloud user, so it names neither of them.
    static func requestName(owner: String, member: String) -> String {
        "keyRequest-" + digest("request-name", [Data(SyncZones.household.utf8), Data(owner.utf8), Data(zoneShareRecordName.utf8),
                                                Data(member.utf8)]).map { String(format: "%02x", $0) }.joined()
    }
    static func offerName(_ requestId: String) -> String { "keyOffer-" + requestId }
    static func grantName(_ requestId: String) -> String { "keyGrant-" + requestId }

    // MARK: Hashes and the code

    /// SHA-256 over the domain, a label and each part length-prefixed.
    static func digest(_ label: String, _ parts: [Data]) -> Data {
        var hash = SHA256()
        hash.update(data: Data((info + "/" + label).utf8))
        for part in parts {
            var count = UInt32(part.count).bigEndian
            hash.update(data: Data(bytes: &count, count: 4))
            hash.update(data: part)
        }
        return Data(hash.finalize())
    }

    /// What her device posts first: it binds the request to the key and nonce it reveals later.
    public static func commitment(requestId: String, publicKey: Data, nonce: Data) -> Data {
        digest("commitment", [Data(requestId.utf8), publicKey, nonce])
    }

    static func transcript(owner: String, member: String, requestId: String, publicKey: Data, memberNonce: Data, adminPublicKey: Data) -> Data {
        digest("transcript", [Data(SyncZones.household.utf8), Data(owner.utf8), Data(member.utf8), Data(requestId.utf8),
                              publicKey, memberNonce, adminPublicKey])
    }

    /// The code both screens show: the first 4 bytes of a SHA-256 over the transcript, big-endian, mod 1,000,000,
    /// zero-padded to 6 digits, as "123 456".
    public static func code(transcript: Data) -> String {
        let bytes = Array(digest("code", [transcript]).prefix(4))
        let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(value).leftPadded(to: 6)
        return digits.prefix(3) + " " + digits.suffix(3)
    }

    // MARK: Sealing the keys

    /// Seals `keys` to `recipient` from the Mac's key `admin`: a fresh ephemeral public key (32 bytes), then the AES-GCM
    /// box (nonce, ciphertext, tag).
    static func seal(_ keys: [SymmetricKey], to recipient: Curve25519.KeyAgreement.PublicKey, from admin: Curve25519.KeyAgreement.PrivateKey,
                     requestId: String, transcript: Data) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let boxKey = try derive([admin.sharedSecretFromKeyAgreement(with: recipient), ephemeral.sharedSecretFromKeyAgreement(with: recipient)],
                                requestId: requestId, transcript: transcript)
        var plaintext = Data()
        for key in keys { key.withUnsafeBytes { plaintext.append(contentsOf: $0) } }
        let context = grantContext(requestId: requestId, admin: admin.publicKey.rawRepresentation, ephemeral: ephemeral.publicKey.rawRepresentation,
                                   recipient: recipient.rawRepresentation, transcript: transcript)
        guard let box = try AES.GCM.seal(plaintext, using: boxKey, authenticating: context).combined else {
            throw ExchangeError.unreadableGrant
        }
        return ephemeral.publicKey.rawRepresentation + box
    }

    /// The keys `sealed` holds, opened with this device's private key and the Mac's public key `admin`; throws when it
    /// isn't from that Mac key, for this device's key, this request and this transcript, or was changed.
    static func open(_ sealed: Data, with privateKey: Curve25519.KeyAgreement.PrivateKey, from admin: Curve25519.KeyAgreement.PublicKey,
                     requestId: String, transcript: Data) throws -> [SymmetricKey] {
        guard sealed.count > 32 + 12 + 16 else { throw ExchangeError.unreadableGrant }
        let ephemeralData = Data(sealed.prefix(32))
        let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralData)
        let boxKey = try derive([privateKey.sharedSecretFromKeyAgreement(with: admin), privateKey.sharedSecretFromKeyAgreement(with: ephemeral)],
                                requestId: requestId, transcript: transcript)
        let context = grantContext(requestId: requestId, admin: admin.rawRepresentation, ephemeral: ephemeralData,
                                   recipient: privateKey.publicKey.rawRepresentation, transcript: transcript)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(sealed.dropFirst(32))), using: boxKey, authenticating: context)
        guard !plaintext.isEmpty, plaintext.count % 32 == 0, plaintext.count <= 32 * maxKeys else { throw ExchangeError.unreadableGrant }
        return stride(from: 0, to: plaintext.count, by: 32).map { offset in
            SymmetricKey(data: plaintext.subdata(in: plaintext.startIndex + offset ..< plaintext.startIndex + offset + 32))
        }
    }

    /// HKDF-SHA256 over the agreements in order (the Mac's key with hers, then the ephemeral with hers).
    private static func derive(_ secrets: [SharedSecret], requestId: String, transcript: Data) throws -> SymmetricKey {
        var material = Data()
        for secret in secrets {
            // A low-order public key makes the agreement all zeros: nobody but the sender of that key could not know it.
            guard secret.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { throw ExchangeError.unreadableGrant }
            secret.withUnsafeBytes { material.append(contentsOf: $0) }
        }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: Data(requestId.utf8),
                                      info: Data((info + "/grant").utf8) + transcript, outputByteCount: 32)
    }

    private static func grantContext(requestId: String, admin: Data, ephemeral: Data, recipient: Data, transcript: Data) -> Data {
        digest("grant", [Data(grantName(requestId).utf8), Data(keyId.utf8), admin, ephemeral, recipient, transcript])
    }

    static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    // MARK: The member's device

    /// The member's device asking for the household key. Its private key and nonce live only in this object's memory:
    /// never stored, never synced; a relaunch starts a new request. One request per iCloud user at a time: starting one
    /// takes down her earlier one (another device's too), and a device whose request was replaced gives up.
    public actor Requester {
        public enum Status: Equatable, Sendable {
            /// Waiting for the Mac to answer the request (`HouseholdCopy.waitingForKey`).
            case waitingForMac
            /// Show the code to the admin (`HouseholdCopy.showCode`), and wait for the grant.
            case showCode(String)
            /// The household keys are stored: sync can open the household.
            case received
            /// The grant didn't open: nothing was stored; start again.
            case refused
            /// No request open (it expired, was replaced by another of her devices, or was received already): start
            /// again.
            case expired
        }

        private struct Pending {
            let requestId: String
            let privateKey: Curve25519.KeyAgreement.PrivateKey
            let nonce: Data
            let commitment: Data
            let startedAt: Date
            var adminKey: Curve25519.KeyAgreement.PublicKey?
            var transcript: Data?
            var code: String?
        }

        private let board: any SyncPublicBoard
        private let transport: any SyncTransport
        private let keys: any SyncKeyStore
        private let member: String
        private let householdOwner: String
        private let name: String
        private var pending: Pending?

        /// `board`: the public database, as her iCloud user. `transport`: her view of `household` (her shared
        /// database). `member`: her iCloud user record name. `householdOwner`: the admin's (the share's owner).
        public init(board: any SyncPublicBoard, transport: any SyncTransport, keys: any SyncKeyStore, member: String, householdOwner: String) {
            self.board = board
            self.transport = transport
            self.keys = keys
            self.member = member
            self.householdOwner = householdOwner
            name = SyncKeyExchange.requestName(owner: householdOwner, member: member)
        }

        /// Posts a new request (a commitment only), replacing any earlier one of hers.
        @discardableResult
        public func start(now: Date) async throws -> Status {
            pending = nil
            try await board.deletePublic(name)
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let nonce = SyncKeyExchange.randomNonce()
            let requestId = UUID().uuidString.lowercased()
            let commitment = SyncKeyExchange.commitment(requestId: requestId, publicKey: privateKey.publicKey.rawRepresentation, nonce: nonce)
            try await board.postPublic(SyncPublicRecord(recordType: requestRecordType, recordName: name,
                                                        fields: [requestIdField: Data(requestId.utf8), commitmentField: commitment]))
            pending = Pending(requestId: requestId, privateKey: privateKey, nonce: nonce, commitment: commitment, startedAt: now)
            return .waitingForMac
        }

        /// Moves the request on: reveals the key once the Mac has answered (then the code shows), and takes the grant
        /// once the admin has confirmed.
        public func poll(now: Date) async throws -> Status {
            guard var current = pending else { return .expired }
            guard abs(now.timeIntervalSince(current.startedAt)) <= lifetime else {
                pending = nil
                try? await board.deletePublic(name)
                return .expired
            }
            // Still this device's request? Another of her devices may have replaced it: then this one gives up, and
            // never writes over the other's.
            let posted = try await board.fetchPublic(name)
            guard let posted, posted.lastModifiedBy == member, posted.fields[requestIdField] == Data(current.requestId.utf8) else {
                if pending?.requestId == current.requestId { pending = nil }
                log.info("Key exchange: this device's request was replaced or is gone; giving up")
                return .expired
            }
            guard let adminKey = current.adminKey, let transcript = current.transcript, let code = current.code else {
                guard let offer = try await transport.fetch(offerName(current.requestId), zone: SyncZones.household) else { return .waitingForMac }
                guard offer.lastModifiedBy == householdOwner, offer.wire.recordType == offerRecordType, offer.wire.unencryptedFields.isEmpty,
                      offer.wire.assets.isEmpty, Set(offer.wire.encryptedFields.keys) == [publicKeyField],
                      let adminData = offer.wire.encryptedFields[publicKeyField], adminData.count == 32,
                      let adminKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: adminData) else {
                    log.error("Key exchange: the Mac's answer isn't the admin's, or isn't the right shape; waiting")
                    return .waitingForMac
                }
                let publicKey = current.privateKey.publicKey.rawRepresentation
                try await board.postPublic(SyncPublicRecord(
                    recordType: requestRecordType, recordName: name,
                    fields: [requestIdField: Data(current.requestId.utf8), commitmentField: current.commitment,
                             publicKeyField: publicKey, nonceField: current.nonce]))
                let transcript = SyncKeyExchange.transcript(owner: householdOwner, member: member, requestId: current.requestId,
                                                            publicKey: publicKey, memberNonce: current.nonce, adminPublicKey: adminData)
                let code = SyncKeyExchange.code(transcript: transcript)
                guard pending?.requestId == current.requestId else { return .expired }
                current.adminKey = adminKey
                current.transcript = transcript
                current.code = code
                pending = current
                return .showCode(code)
            }
            guard let grant = try await transport.fetch(grantName(current.requestId), zone: SyncZones.household) else { return .showCode(code) }
            guard pending?.requestId == current.requestId else { return .expired }
            let opened: [SymmetricKey]
            do {
                let wire = grant.wire
                guard grant.lastModifiedBy == householdOwner, wire.recordType == grantRecordType, wire.unencryptedFields.isEmpty, wire.assets.isEmpty,
                      Set(wire.encryptedFields.keys) == [sealedField, keyIdField], wire.encryptedFields[keyIdField] == Data(keyId.utf8),
                      let sealed = wire.encryptedFields[sealedField] else { throw ExchangeError.unreadableGrant }
                opened = try SyncKeyExchange.open(sealed, with: current.privateKey, from: adminKey, requestId: current.requestId,
                                                  transcript: transcript)
            } catch {
                log.error("Key exchange: the grant doesn't open on this device; nothing stored")
                pending = nil
                try? await board.deletePublic(name)
                return .refused
            }
            for key in opened { try keys.store(key, zone: SyncZones.household) }
            pending = nil
            try? await board.deletePublic(name)
            log.info("Key exchange: the household keys arrived (\(opened.count, privacy: .public))")
            return .received
        }
    }

    // MARK: The admin's Mac

    /// What the Mac remembers between launches, per member (`syncState`, key `keyExchangeLedger.<member>`): no key
    /// material, only request ids, times and a count.
    struct Ledger: Codable, Equatable {
        /// Requests never answered again (granted, declined, refused, expired), until the time they can't be fresh anyway.
        var closed: [String: Date] = [:]
        /// When each declined or refused code happened; only the last `failureWindow` counts towards the lockout.
        var failedAt: [Date] = []
        /// No request of hers is answered before this time.
        var lockedUntil: Date?

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            closed = try c.decodeIfPresent([String: Date].self, forKey: .closed) ?? [:]
            failedAt = try c.decodeIfPresent([Date].self, forKey: .failedAt) ?? []
            lockedUntil = try c.decodeIfPresent(Date.self, forKey: .lockedUntil)
        }

        /// The lockout still in force at `now`, never later than `lockout` from now (a clock set far ahead once, or a
        /// tampered value, can't lock her out for longer).
        func activeLock(now: Date) -> Date? {
            guard let until = lockedUntil, until > now else { return nil }
            return min(until, now.addingTimeInterval(SyncKeyExchange.lockout))
        }

        static func key(member: String) -> String { "keyExchangeLedger." + member }

        static func load(member: String, db: Database) throws -> Ledger {
            guard let data = try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key(member: member)]) else {
                return Ledger()
            }
            return (try? JSONDecoder().decode(Ledger.self, from: data)) ?? Ledger()
        }

        func save(member: String, db: Database, now: Date) throws {
            var kept = self
            kept.closed = closed.filter { $0.value > now }
            try SyncImportGate.setState(try JSONEncoder().encode(kept), key: Self.key(member: member), db: db, now: now)
        }
    }

    /// The admin's Mac answering the member's request. The private half of its answer key and the commitment it kept
    /// live in this object's memory only; which requests are closed, and the attempt count, are kept in `db`
    /// (`Ledger`), so a relaunch never answers a closed request again.
    public actor Granter {
        private struct Answered {
            let requestId: String
            let commitment: Data
            let privateKey: Curve25519.KeyAgreement.PrivateKey
            let answeredAt: Date
        }

        private let board: any SyncPublicBoard
        private let transport: any SyncTransport & SyncShareTransport
        private let member: String
        private let db: any DatabaseWriter
        private var owner: String?
        private var answered: Answered?
        /// Requests whose offer and grant are deleted once her request is gone.
        private var toClear: Set<String> = []

        /// `board`: the public database. `transport`: the household zone and its share, as the owner. `member`: her
        /// iCloud user record name, as the Mac bound it. `db`: this Mac's database (`syncState`).
        public init(board: any SyncPublicBoard, transport: any SyncTransport & SyncShareTransport, member: String, db: any DatabaseWriter) {
            self.board = board
            self.transport = transport
            self.member = member
            self.db = db
        }

        /// Until when the Mac answers no request of hers, after too many declined or refused codes
        /// (`HouseholdCopy.tooManyAttempts`); nil when it answers.
        public func lockedUntil(now: Date) async throws -> Date? {
            let ledger = try await ledger()
            return ledger.activeLock(now: now)
        }

        /// Her request, once her device has revealed its key: show its code and ask the admin to confirm. Nil while
        /// there is nothing to confirm (none, not hers, not revealed yet, expired, closed, locked, or she isn't on the
        /// share); answers a new request with this Mac's key, and tidies up after one she has taken down.
        public func poll(now: Date) async throws -> Request? {
            let name = SyncKeyExchange.requestName(owner: try await ownerName(), member: member)
            guard let record = try await board.fetchPublic(name) else {
                try await clearUp()
                return nil
            }
            guard record.recordType == requestRecordType, record.lastModifiedBy == member,
                  let idData = record.fields[requestIdField], let id = String(data: idData, encoding: .utf8), UUID(uuidString: id) != nil,
                  let commitment = record.fields[commitmentField], commitment.count == 32 else {
                log.error("Key exchange: a request not written by the member, or not the right shape; ignored")
                return nil
            }
            var current = try await ledger()
            if let until = current.lockedUntil, until > now.addingTimeInterval(lockout) {
                // A lock further out than a lockout can be: keep it at a lockout from now, so it ends.
                try await self.record(now: now) { $0.lockedUntil = now.addingTimeInterval(lockout) }
                current = try await ledger()
            }
            let ledger = current
            guard ledger.closed[id] == nil else { return nil }
            guard try await isMember() else {
                log.error("Key exchange: a request from someone not on the household share; ignored")
                return nil
            }
            guard let answered, answered.requestId == id else {
                if ledger.activeLock(now: now) != nil { return nil }
                return try await answer(id: id, commitment: commitment, postedAt: record.modifiedAt, now: now)
            }
            guard now.timeIntervalSince(answered.answeredAt) <= lifetime else {
                try await close(id, now: now, failed: false)
                return nil
            }
            guard record.fields[commitmentField] == answered.commitment else {
                log.error("Key exchange: the request's commitment changed after the answer; refused")
                try await close(id, now: now, failed: true)
                return nil
            }
            guard let publicKey = record.fields[publicKeyField], let memberNonce = record.fields[nonceField] else { return nil }
            guard memberNonce.count == 32, (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)) != nil,
                  SyncKeyExchange.commitment(requestId: id, publicKey: publicKey, nonce: memberNonce) == answered.commitment else {
                log.error("Key exchange: the revealed key doesn't match the commitment; refused")
                try await close(id, now: now, failed: true)
                return nil
            }
            let transcript = SyncKeyExchange.transcript(owner: try await ownerName(), member: member, requestId: id, publicKey: publicKey,
                                                        memberNonce: memberNonce, adminPublicKey: answered.privateKey.publicKey.rawRepresentation)
            return Request(id: id, code: SyncKeyExchange.code(transcript: transcript), lastModifiedBy: member, publicKey: publicKey,
                           transcript: transcript)
        }

        /// The admin confirmed the code: seals every household key to her device and saves the grant, once.
        public func grant(_ request: Request, keys: any SyncKeyStore, now: Date) async throws {
            guard let answered, answered.requestId == request.id, try await ledger().closed[request.id] == nil else {
                throw ExchangeError.notConfirmable
            }
            guard now.timeIntervalSince(answered.answeredAt) <= lifetime else {
                try await close(request.id, now: now, failed: false)
                throw ExchangeError.expired
            }
            guard try await isMember() else {
                try await close(request.id, now: now, failed: false)
                throw ExchangeError.notAMember
            }
            let held = try keys.allKeys(zone: SyncZones.household)
            guard !held.isEmpty else { throw ExchangeError.noKeys }
            guard held.count <= maxKeys else { throw ExchangeError.tooManyKeys }
            // The newest key goes last, so it is her newest too.
            let newest = try keys.key(zone: SyncZones.household).map(DocumentCrypto.zoneKeyId)
            let ordered = held.sorted { ($0.key == newest ? 1 : 0, $0.key) < ($1.key == newest ? 1 : 0, $1.key) }.map(\.value)
            let sealed = try SyncKeyExchange.seal(ordered, to: Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKey),
                                                  from: answered.privateKey, requestId: request.id, transcript: request.transcript)
            let wire = SyncWireRecord(recordType: grantRecordType, recordName: grantName(request.id), zone: SyncZones.household,
                                      encryptedFields: [sealedField: sealed, keyIdField: Data(keyId.utf8)])
            // Create only: one grant per request, whatever is pressed again.
            let result = try await transport.save([wire], ifUnchanged: [:], atomic: false).first?.outcome
            switch result {
            case .saved:
                try await record(now: now) { ledger in
                    ledger.closed[request.id] = now.addingTimeInterval(lifetime)
                    ledger.failedAt = []
                }
                self.answered = nil
                toClear.insert(request.id)
                log.info("Key exchange: the household keys were sealed to the member's device (\(ordered.count, privacy: .public))")
            case .failed, .batchRequestFailed, .none:
                throw SyncTransportError.unavailable(retryAfter: nil)
            default:
                try await close(request.id, now: now, failed: false)
                throw ExchangeError.notConfirmable
            }
        }

        /// "Not now": the request is never answered again, also after a relaunch; it counts as a failed attempt. She
        /// starts a new one to try again.
        public func decline(_ request: Request, now: Date) async throws {
            try await close(request.id, now: now, failed: true)
        }

        private func ownerName() async throws -> String {
            if let owner { return owner }
            let name = try await transport.currentUserRecordName()
            owner = name
            return name
        }

        private func ledger() async throws -> Ledger {
            let member = member
            return try await db.read { db in try Ledger.load(member: member, db: db) }
        }

        private func record(now: Date, _ change: @escaping @Sendable (inout Ledger) -> Void) async throws {
            let member = member
            try await db.write { db in
                var ledger = try Ledger.load(member: member, db: db)
                change(&ledger)
                try ledger.save(member: member, db: db, now: now)
            }
        }

        private func isMember() async throws -> Bool {
            let share = try await transport.zoneShare(SyncZones.household)
            return share?.participants.contains { $0.userRecordName == member && $0.status == .accepted } ?? false
        }

        /// Answers a new request with an ephemeral key, if it is fresh.
        private func answer(id: String, commitment: Data, postedAt: Date?, now: Date) async throws -> Request? {
            guard let postedAt, abs(now.timeIntervalSince(postedAt)) <= lifetime else {
                log.error("Key exchange: a request too old to answer; ignored")
                try await record(now: now) { $0.closed[id] = now.addingTimeInterval(lifetime) }
                return nil
            }
            if let earlier = answered { try await close(earlier.requestId, now: now, failed: false) }
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let offer = SyncWireRecord(recordType: offerRecordType, recordName: offerName(id), zone: SyncZones.household,
                                       encryptedFields: [publicKeyField: privateKey.publicKey.rawRepresentation])
            switch try await transport.save([offer], ifUnchanged: [:], atomic: false).first?.outcome {
            case .saved:
                answered = Answered(requestId: id, commitment: commitment, privateKey: privateKey, answeredAt: now)
                toClear.insert(id)
            case .failed, .batchRequestFailed, .none:
                break
            default:
                // An answer is there already (this Mac's before a relaunch): its private key is gone, so this request is.
                try await close(id, now: now, failed: false)
            }
            return nil
        }

        /// Closes the request (kept closed across launches) and deletes what this Mac wrote for it; `failed`: a declined
        /// or refused code, counted towards the lockout.
        private func close(_ id: String, now: Date, failed: Bool) async throws {
            if answered?.requestId == id { answered = nil }
            try await record(now: now) { ledger in
                ledger.closed[id] = now.addingTimeInterval(lifetime)
                guard failed else { return }
                ledger.failedAt = ledger.failedAt.filter { now.timeIntervalSince($0) < failureWindow } + [now]
                if ledger.failedAt.count >= maxFailedAttempts {
                    ledger.failedAt = []
                    ledger.lockedUntil = now.addingTimeInterval(lockout)
                }
            }
            try await transport.delete([offerName(id), grantName(id)], zone: SyncZones.household)
            toClear.remove(id)
        }

        /// Her request is gone (taken, given up, or replaced by none): what this Mac wrote for it goes too.
        private func clearUp() async throws {
            answered = nil
            for id in toClear.sorted() { try await transport.delete([offerName(id), grantName(id)], zone: SyncZones.household) }
            toClear = []
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
