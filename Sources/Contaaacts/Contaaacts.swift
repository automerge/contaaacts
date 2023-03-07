import Automerge
import Foundation
import Network

@main
struct Contaaacts {
    public static func main() {
        let args = CommandLine.arguments
        switch args[1] {
        case "create":
            create(filename: args[2])
        case "add":
            add(filename: args[2], name: args[4], email: args[6])
        case "list":
            list(filename: args[2])
        case "update":
            update(filename: args[2], contact: args[4], newEmail: args[6])
        case "merge":
            merge(filename1: args[2], filename2: args[3], out: args[4])
        case "serve":
            serve(filename: args[2], port: args[3])
        case "sync":
            sync(filename: args[2], server: args[3], port: args[4])
        default:
            print("unknown command")
        }
    }
}

func create(filename: String) {
    let skeletonUrl = Bundle.module.url(forResource: "skeleton", withExtension: "")!
    let data = try! Data(contentsOf: skeletonUrl)
    let output = URL(fileURLWithPath: filename)
    try! data.write(to: output)
}

func add(filename: String, name: String, email: String) {
    let bytes = try! Data(contentsOf: URL(fileURLWithPath: filename))
    let document = try! Document([UInt8](bytes))
    let contacts: ObjId
    switch try! document.get(obj: ObjId.ROOT, key: "contacts")! {
    case .Object(let id, _):
        contacts = id
    default:
        fatalError("contacts was not a list")
    }

    let lastIndex = document.length(obj: contacts)

    // Insert a new map for the new contact at the end of the contacts list
    let newContact = try! document.insertObject(obj: contacts, index: lastIndex, ty: .Map)

    // Set the name to a text field
    let nameText = try! document.putObject(obj: newContact, key: "name", ty: .Text)
    try! document.spliceText(obj: nameText, start:0, delete:0, value: name)

    // Set the email to a text field
    let emailText = try! document.putObject(obj: newContact, key: "email", ty: .Text)
    try! document.spliceText(obj: emailText, start:0, delete:0, value: email)

    // now save the document to the filesystem
    let savedBytes = document.save()
    let data = Data(bytes: savedBytes, count:savedBytes.count)
    let output = URL(fileURLWithPath: filename)
    try! data.write(to: output)
}

func list(filename: String) {
    let bytes = try! Data(contentsOf: URL(fileURLWithPath: filename))
    let document = try! Document([UInt8](bytes))
    let contacts: ObjId
    switch try! document.get(obj: ObjId.ROOT, key: "contacts")! {
    case .Object(let id, _):
        contacts = id
    default:
        fatalError("contacts was not a list")
    }

    for value in try! document.values(obj: contacts) {
        switch value {
        case .Object(let contact, .Map):
            let nameId: ObjId
            switch try! document.get(obj: contact, key: "name")! {
            case .Object(let id, .Text):
                nameId = id
            default:
                fatalError("contact name was not a text object")
            }

            let emailId: ObjId
            switch try! document.get(obj: contact, key: "email")! {
            case .Object(let id, .Text):
                emailId = id
            default:
                fatalError("contact email was not a text object")
            }

            let name = try! document.text(obj: nameId)
            let email = try! document.text(obj: emailId)
            print("\(name): \(email)")
        default:
            fatalError("unexpected value in contacts")
        }
    }
}

func update(filename: String, contact: String, newEmail: String) {
    let bytes = try! Data(contentsOf: URL(fileURLWithPath: filename))
    let document = try! Document([UInt8](bytes))
    let contacts: ObjId
    switch try! document.get(obj: ObjId.ROOT, key: "contacts")! {
    case .Object(let id, _):
        contacts = id
    default:
        fatalError("contacts was not a list")
    }

    var found = false
    for value in try! document.values(obj:contacts) {
        switch value {
        case .Object(let contactId, .Map):
            let nameId: ObjId
            switch try! document.get(obj: contactId, key: "name")! {
            case .Object(let id, .Text):
                nameId = id
            default:
                fatalError("contact name was not a text object")
            }

            let name = try! document.text(obj: nameId)
            if name == contact.trimmingCharacters(in: .whitespacesAndNewlines) {
                found = true
                let newEmailId = try! document.putObject(obj: contactId, key: "email", ty: .Text)
                try! document.spliceText(obj:newEmailId, start:0, delete:0, value: newEmail)
                break;
            }
        default:
            continue
        }
    }
    if !found {
        fatalError("contact \(contact) not found")
    }

    // now save the document to the filesystem
    let savedBytes = document.save()
    let data = Data(bytes: savedBytes, count:savedBytes.count)
    let output = URL(fileURLWithPath: filename)
    try! data.write(to: output)
}

func merge(filename1: String, filename2: String, out: String) {
    let leftBytes = try! Data(contentsOf: URL(fileURLWithPath: filename1))
    let left = try! Document([UInt8](leftBytes))

    let rightBytes = try! Data(contentsOf: URL(fileURLWithPath: filename2))
    let right = try! Document([UInt8](rightBytes))

    try! left.merge(other: right)
    let savedBytes = left.save()
    let data = Data(bytes: savedBytes, count:savedBytes.count)
    let output = URL(fileURLWithPath: out)
    try! data.write(to: output)
}

func serve(filename: String, port: String) {
    let bytes = try! Data(contentsOf: URL(fileURLWithPath: filename))
    let document = try! Document([UInt8](bytes))

    let listener = syncListener(port: port)
    listener.newConnectionHandler = { conn in
        conn.start(queue: .global(qos: .default))
        Task {
            try! await withReadyConnection(connection: conn) { connection in
                do {
                    let syncState = SyncState()
                    repeat {
                        guard let msg = try await receiveMsg(connection: connection) else {
                            continue
                        }
                        try document.receiveSyncMessage(state: syncState, message: msg)
                        if let resp = document.generateSyncMessage(state: syncState) {
                            try await sendMsg(connection: connection, msg: resp)
                        }
                    } while connection.state == .ready 
                } catch {
                    print("error in connection \(error)")
                }
            }
        }
    }
    listener.start(queue: .global(qos: .default))
    dispatchMain()
}

func syncListener(port: String) -> NWListener {
    let parameters = NWParameters.tcp
    let syncOptions = NWProtocolFramer.Options(definition: SyncProtocol.definition)
    parameters.defaultProtocolStack.applicationProtocols.insert(syncOptions, at: 0)

    let listener = try! NWListener(using: parameters, on: NWEndpoint.Port(port)!)
    listener.stateUpdateHandler = { state in 
        if state == .ready, let port = listener.port {
            print("listening on \(port)")
        }
    }
    return listener
}

func sync(filename: String, server: String, port: String) {
    let bytes = try! Data(contentsOf: URL(fileURLWithPath: filename))
    let document = try! Document([UInt8](bytes))

    let conn = syncConnection(server:server, port:port)
    conn.start(queue: .global(qos: .default))

    let group = DispatchGroup()
    group.enter()
    Task.detached(priority: .userInitiated) {
        try! await withReadyConnection(connection: conn) { connection in
            let syncState = SyncState()
            let initialSyncMsg = document.generateSyncMessage(state: syncState)!
            try! await sendMsg(connection: connection, msg: initialSyncMsg)
            var upToDate = false
            repeat {
                let msg = try! await receiveMsg(connection: connection)!
                try! document.receiveSyncMessage(state: syncState, message: msg)
                if let resp = document.generateSyncMessage(state: syncState) {
                    try! await sendMsg(connection: connection, msg: resp)
                }
                if let theirHeads = syncState.theirHeads, theirHeads == document.heads() {
                    upToDate = true
                }
            } while connection.state == .ready && !upToDate
        }
        group.leave()
    }
    group.wait()

    let savedBytes = document.save()
    let data = Data(bytes: savedBytes, count:savedBytes.count)
    let output = URL(fileURLWithPath: filename)
    try! data.write(to: output)
}

func syncConnection(server: String, port: String) -> NWConnection {
    let parameters = NWParameters.tcp
    let syncOptions = NWProtocolFramer.Options(definition: SyncProtocol.definition)
    parameters.defaultProtocolStack.applicationProtocols.insert(syncOptions, at: 0)

    return NWConnection(host: NWEndpoint.Host(server), port: NWEndpoint.Port(port)!, using: parameters)
}


enum ConnectionError: Error {
    case Cancelled
    case Failed(NWError)
}

func withReadyConnection(connection: NWConnection, onReady: @escaping (NWConnection) async -> Void) async throws {
    try await withCheckedThrowingContinuation(function: "withReadyConnection", { (cont: CheckedContinuation<Void, any Error>) in 
        var task: Task<Void, any Error>? = nil
        connection.stateUpdateHandler = {  newState in
            switch newState {
            case .ready:
                if task != nil {
                    return
                }
                task = Task {
                    await onReady(connection)
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    cont.resume(returning: ())
                } 

            case .failed(let error):
                connection.cancel()
                connection.stateUpdateHandler = nil
                task?.cancel()
                cont.resume(throwing: ConnectionError.Failed(error))
            case .cancelled:
                connection.stateUpdateHandler = nil
                task?.cancel()
                cont.resume(throwing: ConnectionError.Cancelled)
            default:
                return
            }
        }
    })
}

func receiveMsg(connection: NWConnection) async throws -> [UInt8]? {
    try await withCheckedThrowingContinuation(function: "receiveMessage", { cont in 
        connection.receiveMessage { (content, context, isComplete, error) in
            if let error = error {
                cont.resume(throwing: error)
                return
            }
            guard let content = content else {
                cont.resume(returning: nil)
                return
            }
            let incoming = [UInt8](content)
            cont.resume(returning: incoming)
        }
    })
}

func sendMsg(connection: NWConnection, msg: [UInt8]) async throws -> Void {
    let nwMsg = NWProtocolFramer.Message(definition: SyncProtocol.definition)
    let context = NWConnection.ContentContext(
        identifier: "sync",
        metadata: [nwMsg])
    try await withCheckedThrowingContinuation(function: "sendMsg", { (cont: CheckedContinuation<Void, any Error>) in 
        connection.send(
            content: msg,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed(
                {error in 
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: ())
                    }
                })
        )
    })
}
